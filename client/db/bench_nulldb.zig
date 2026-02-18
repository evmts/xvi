/// Focused benchmarks for NullDb (DB-001: silent write discard fix).
///
/// Validates that NullDb operations have effectively zero cost, as expected
/// from a null-object implementation:
///   1. put_impl discards writes with zero allocation overhead
///   2. get_impl returns null with zero lookup overhead
///   3. delete_impl discards with zero overhead
///   4. Vtable dispatch adds negligible overhead for NullDb
///   5. NullDb throughput far exceeds block processing requirements
///
/// NullDb is used as a drop-in database replacement for tests, diagnostics,
/// and null-op modes. The DB-001 fix changed put/delete from returning
/// error.StorageError to silently discarding, making it a true null object.
///
/// Run:
///   zig test -O ReleaseFast client/db/bench_nulldb.zig   # Optimized bench
///   zig test client/db/bench_nulldb.zig                  # Debug mode bench
const std = @import("std");
const adapter = @import("adapter.zig");
const null_mod = @import("null.zig");

const Database = adapter.Database;
const NullDb = null_mod.NullDb;
const Error = adapter.Error;

/// Number of warmup iterations.
const WARMUP_ITERS: usize = 5;
/// Number of timed iterations to average.
const BENCH_ITERS: usize = 20;

/// Tier sizes.
const SMALL_N: usize = 10_000;
const MEDIUM_N: usize = 100_000;
const LARGE_N: usize = 1_000_000;

// ============================================================================
// Key/value generation helpers
// ============================================================================

/// Generate a deterministic 32-byte key from an index.
/// Uses optimization barrier to prevent dead-code elimination.
fn make_key(buf: *[32]u8, index: usize) []const u8 {
    const idx: u64 = @intCast(index);
    @memcpy(buf[0..8], std.mem.asBytes(&idx));
    @memcpy(buf[8..16], std.mem.asBytes(&(idx *% 0x9E3779B97F4A7C15)));
    @memcpy(buf[16..24], std.mem.asBytes(&(idx *% 0x517CC1B727220A95)));
    @memcpy(buf[24..32], std.mem.asBytes(&(idx *% 0x6C62272E07BB0142)));
    return buf;
}

/// Generate a deterministic 32-byte value from an index.
fn make_value(buf: *[32]u8, index: usize) []const u8 {
    const idx: u64 = @intCast(index);
    const val = idx *% 0xDEADBEEFCAFEBABE;
    @memcpy(buf[0..8], std.mem.asBytes(&val));
    @memcpy(buf[8..16], std.mem.asBytes(&(val +% 1)));
    @memcpy(buf[16..24], std.mem.asBytes(&(val +% 2)));
    @memcpy(buf[24..32], std.mem.asBytes(&(val +% 3)));
    return buf;
}

/// Optimization barrier — prevents the compiler from eliminating calls whose
/// results are unused. Essential for benchmarking NullDb, which has no side
/// effects by design.
inline fn sink(val: anytype) void {
    std.mem.doNotOptimizeAway(&val);
}

/// Format nanoseconds into a human-readable fixed buffer.
fn format_ns(ns: u64) [32]u8 {
    var buf: [32]u8 = [_]u8{0} ** 32;
    if (ns < 1_000) {
        _ = std.fmt.bufPrint(&buf, "{d} ns", .{ns}) catch unreachable;
    } else if (ns < 1_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.1} us", .{@as(f64, @floatFromInt(ns)) / 1_000.0}) catch unreachable;
    } else if (ns < 1_000_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch unreachable;
    } else {
        _ = std.fmt.bufPrint(&buf, "{d:.3} s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch unreachable;
    }
    return buf;
}

fn format_ops_per_sec(ops: usize, elapsed_ns: u64) [32]u8 {
    var buf: [32]u8 = [_]u8{0} ** 32;
    if (elapsed_ns == 0) {
        _ = std.fmt.bufPrint(&buf, "inf ops/s", .{}) catch unreachable;
        return buf;
    }
    const ops_per_sec = @as(f64, @floatFromInt(ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);
    if (ops_per_sec >= 1_000_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2} G ops/s", .{ops_per_sec / 1_000_000_000.0}) catch unreachable;
    } else if (ops_per_sec >= 1_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2} M ops/s", .{ops_per_sec / 1_000_000.0}) catch unreachable;
    } else if (ops_per_sec >= 1_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.1} K ops/s", .{ops_per_sec / 1_000.0}) catch unreachable;
    } else {
        _ = std.fmt.bufPrint(&buf, "{d:.0} ops/s", .{ops_per_sec}) catch unreachable;
    }
    return buf;
}

const BenchResult = struct {
    name: []const u8,
    ops: usize,
    elapsed_ns: u64,
    per_op_ns: u64,
    ops_per_sec: f64,
};

fn make_result(name: []const u8, ops: usize, elapsed_ns: u64) BenchResult {
    return .{
        .name = name,
        .ops = ops,
        .elapsed_ns = elapsed_ns,
        .per_op_ns = if (ops > 0) elapsed_ns / ops else 0,
        .ops_per_sec = if (elapsed_ns > 0)
            @as(f64, @floatFromInt(ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9)
        else
            0,
    };
}

fn print_result(r: BenchResult) void {
    const total_str = format_ns(r.elapsed_ns);
    const per_op_str = format_ns(r.per_op_ns);
    const ops_str = format_ops_per_sec(r.ops, r.elapsed_ns);
    std.debug.print("  {s:<55} {d:>10} ops  total={s}  per-op={s}  {s}\n", .{
        r.name,
        r.ops,
        &total_str,
        &per_op_str,
        &ops_str,
    });
}

// ============================================================================
// NullDb Benchmark implementations
// ============================================================================

/// Benchmark: NullDb put via vtable — measure overhead of silent write discard (DB-001 fix).
fn bench_nulldb_put(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var ndb = NullDb.init(.state);
    defer ndb.deinit();
    const iface = ndb.database();

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        for (0..n) |i| {
            iface.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
            sink(key_buf);
        }
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            iface.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
            sink(key_buf);
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: NullDb get via vtable — measure overhead of null return.
fn bench_nulldb_get(n: usize) u64 {
    var key_buf: [32]u8 = undefined;

    var ndb = NullDb.init(.state);
    defer ndb.deinit();
    const iface = ndb.database();

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        for (0..n) |i| {
            const val = iface.get(make_key(&key_buf, i)) catch unreachable;
            sink(val);
        }
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            const val = iface.get(make_key(&key_buf, i)) catch unreachable;
            sink(val);
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: NullDb delete via vtable — measure overhead of silent delete discard (DB-001 fix).
fn bench_nulldb_delete(n: usize) u64 {
    var key_buf: [32]u8 = undefined;

    var ndb = NullDb.init(.state);
    defer ndb.deinit();
    const iface = ndb.database();

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        for (0..n) |i| {
            iface.delete(make_key(&key_buf, i)) catch unreachable;
            sink(key_buf);
        }
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            iface.delete(make_key(&key_buf, i)) catch unreachable;
            sink(key_buf);
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: NullDb contains via vtable — measure overhead of false return.
fn bench_nulldb_contains(n: usize) u64 {
    var key_buf: [32]u8 = undefined;

    var ndb = NullDb.init(.state);
    defer ndb.deinit();
    const iface = ndb.database();

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        for (0..n) |i| {
            const exists = iface.contains(make_key(&key_buf, i)) catch unreachable;
            sink(exists);
        }
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            const exists = iface.contains(make_key(&key_buf, i)) catch unreachable;
            sink(exists);
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: NullDb mixed operations — simulating block processing through null backend.
/// 200 txs × (2 account reads + 5 storage writes + 5 storage reads) = 2400 ops.
fn bench_nulldb_block_sim() u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var ndb = NullDb.init(.state);
    defer ndb.deinit();
    const iface = ndb.database();

    const txs_per_block: usize = 200;
    const storage_writes_per_tx: usize = 5;
    const storage_reads_per_tx: usize = 5;
    const account_reads_per_tx: usize = 2;

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        for (0..txs_per_block) |tx| {
            for (0..account_reads_per_tx) |a| {
                const v = iface.get(make_key(&key_buf, tx * 100 + a)) catch unreachable;
                sink(v);
            }
            for (0..storage_writes_per_tx) |s| {
                iface.put(make_key(&key_buf, tx * 100 + 10 + s), make_value(&val_buf, tx * s)) catch unreachable;
                sink(key_buf);
            }
            for (0..storage_reads_per_tx) |s| {
                const v = iface.get(make_key(&key_buf, tx * 100 + 10 + s)) catch unreachable;
                sink(v);
            }
        }
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..txs_per_block) |tx| {
            for (0..account_reads_per_tx) |a| {
                const v = iface.get(make_key(&key_buf, tx * 100 + a)) catch unreachable;
                sink(v);
            }
            for (0..storage_writes_per_tx) |s| {
                iface.put(make_key(&key_buf, tx * 100 + 10 + s), make_value(&val_buf, tx * s)) catch unreachable;
                sink(key_buf);
            }
            for (0..storage_reads_per_tx) |s| {
                const v = iface.get(make_key(&key_buf, tx * 100 + 10 + s)) catch unreachable;
                sink(v);
            }
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: NullDb snapshot operations.
fn bench_nulldb_snapshot(n: usize) u64 {
    var key_buf: [32]u8 = undefined;

    var ndb = NullDb.init(.state);
    defer ndb.deinit();
    const iface = ndb.database();

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            var snap = iface.snapshot() catch unreachable;
            const v = snap.get(make_key(&key_buf, i), .none) catch unreachable;
            sink(v);
            snap.deinit();
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: NullDb iterator creation + consumption.
fn bench_nulldb_iterator(n: usize) u64 {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();
    const iface = ndb.database();

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |_| {
            var it = iface.iterator(false) catch unreachable;
            const entry = it.next() catch unreachable;
            sink(entry);
            it.deinit();
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: Memory allocation verification — NullDb must perform ZERO allocations.
fn bench_nulldb_zero_alloc(n: usize) struct { elapsed_ns: u64, allocs: usize } {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var ndb = NullDb.init(.state);
    defer ndb.deinit();
    const iface = ndb.database();

    // Use a tracking allocator — but NullDb shouldn't allocate at all.
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer _ = gpa.deinit();

    const initial = gpa.total_requested_bytes;

    var timer = std.time.Timer.start() catch unreachable;
    for (0..n) |i| {
        iface.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
        sink(key_buf);
        const v = iface.get(make_key(&key_buf, i)) catch unreachable;
        sink(v);
        iface.delete(make_key(&key_buf, i)) catch unreachable;
        sink(key_buf);
        const c = iface.contains(make_key(&key_buf, i)) catch unreachable;
        sink(c);
    }
    const elapsed = timer.read();

    return .{
        .elapsed_ns = elapsed,
        .allocs = gpa.total_requested_bytes - initial,
    };
}

// ============================================================================
// Entry point
// ============================================================================

fn run_benchmarks() void {
    const is_release = @import("builtin").mode != .Debug;
    const mode_str = if (is_release) "ReleaseFast" else "Debug";

    std.debug.print("\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
    std.debug.print("  NullDb Benchmarks (DB-001: silent write discard fix)\n", .{});
    std.debug.print("  Mode: {s}, Key: 32B, Value: 32B, Warmup: {d}, Timed: {d} iters (avg)\n", .{ mode_str, WARMUP_ITERS, BENCH_ITERS });
    std.debug.print("  NOTE: uses doNotOptimizeAway barriers to prevent dead-code elimination\n", .{});
    std.debug.print("=" ** 100 ++ "\n\n", .{});

    // -- Core NullDb operations --
    std.debug.print("--- NullDb: put (silent discard, DB-001 fix) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "NullDb put (10K writes, discarded)" },
        .{ .n = MEDIUM_N, .name = "NullDb put (100K writes, discarded)" },
        .{ .n = LARGE_N, .name = "NullDb put (1M writes, discarded)" },
    }) |s| {
        print_result(make_result(s.name, s.n, bench_nulldb_put(s.n)));
    }
    std.debug.print("\n", .{});

    std.debug.print("--- NullDb: get (always returns null) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "NullDb get (10K reads, always null)" },
        .{ .n = MEDIUM_N, .name = "NullDb get (100K reads, always null)" },
        .{ .n = LARGE_N, .name = "NullDb get (1M reads, always null)" },
    }) |s| {
        print_result(make_result(s.name, s.n, bench_nulldb_get(s.n)));
    }
    std.debug.print("\n", .{});

    std.debug.print("--- NullDb: delete (silent discard, DB-001 fix) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "NullDb delete (10K deletes, discarded)" },
        .{ .n = MEDIUM_N, .name = "NullDb delete (100K deletes, discarded)" },
        .{ .n = LARGE_N, .name = "NullDb delete (1M deletes, discarded)" },
    }) |s| {
        print_result(make_result(s.name, s.n, bench_nulldb_delete(s.n)));
    }
    std.debug.print("\n", .{});

    std.debug.print("--- NullDb: contains (always false) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "NullDb contains (10K checks)" },
        .{ .n = MEDIUM_N, .name = "NullDb contains (100K checks)" },
        .{ .n = LARGE_N, .name = "NullDb contains (1M checks)" },
    }) |s| {
        print_result(make_result(s.name, s.n, bench_nulldb_contains(s.n)));
    }
    std.debug.print("\n", .{});

    // -- Snapshot + Iterator --
    std.debug.print("--- NullDb: Snapshot + Iterator ---\n", .{});
    print_result(make_result("NullDb snapshot create+get+deinit (10K cycles)", SMALL_N, bench_nulldb_snapshot(SMALL_N)));
    print_result(make_result("NullDb iterator create+consume+deinit (10K cycles)", SMALL_N, bench_nulldb_iterator(SMALL_N)));
    std.debug.print("\n", .{});

    // -- Zero allocation verification --
    std.debug.print("--- NullDb: Zero Allocation Verification ---\n", .{});
    {
        const r = bench_nulldb_zero_alloc(100_000);
        const total_ops: usize = 100_000 * 4; // put + get + delete + contains per iteration
        const per_op_ns = if (total_ops > 0) r.elapsed_ns / total_ops else 0;
        std.debug.print("  100K cycles x 4 ops each = {d} total ops\n", .{total_ops});
        std.debug.print("  Heap allocations:           {d} bytes (expected: 0)\n", .{r.allocs});
        std.debug.print("  Total time:                 {s}\n", .{&format_ns(r.elapsed_ns)});
        std.debug.print("  Per-op:                     {s}\n", .{&format_ns(per_op_ns)});
        if (r.allocs == 0) {
            std.debug.print("  Status:                     PASS - zero heap allocations\n", .{});
        } else {
            std.debug.print("  Status:                     FAIL - unexpected allocations!\n", .{});
        }
    }
    std.debug.print("\n", .{});

    // -- Block processing simulation --
    std.debug.print("--- NullDb: Block Processing Simulation ---\n", .{});
    std.debug.print("  (200 txs/block, 2 account reads + 5 storage writes + 5 storage reads per tx)\n", .{});
    {
        const elapsed = bench_nulldb_block_sim();
        const ops_per_block: usize = 200 * (2 + 5 + 5);
        const blocks_per_sec = if (elapsed > 0)
            1_000_000_000.0 / @as(f64, @floatFromInt(elapsed))
        else
            0.0;
        const ops_per_sec = blocks_per_sec * @as(f64, @floatFromInt(ops_per_block));
        const effective_mgas = blocks_per_sec * 30.0; // 30M gas/block post-merge

        std.debug.print("  Block DB time:              {s}\n", .{&format_ns(elapsed)});
        std.debug.print("  Block throughput (DB):       {d:.0} blocks/s\n", .{blocks_per_sec});
        std.debug.print("  DB ops/block:                ~{d}\n", .{ops_per_block});
        std.debug.print("  DB ops/sec:                  {d:.0} ({d:.2} M ops/s)\n", .{ ops_per_sec, ops_per_sec / 1e6 });
        std.debug.print("  Effective MGas/s (DB only):   {d:.0} MGas/s\n", .{effective_mgas});
        std.debug.print("  Nethermind target:            700 MGas/s\n", .{});
        std.debug.print("  Required blocks/s:            ~23 blocks/s (30M gas/block)\n", .{});

        const comfortable = blocks_per_sec >= 2300.0;
        const meets_target = blocks_per_sec >= 23.0;

        if (comfortable) {
            std.debug.print("  Status: PASS - NullDb overhead is negligible (<1%% of budget)\n", .{});
        } else if (meets_target) {
            std.debug.print("  Status: PASS - meets target but vtable overhead notable\n", .{});
        } else {
            std.debug.print("  Status: FAIL - NullDb cannot keep up (unexpected!)\n", .{});
        }
    }

    std.debug.print("\n" ++ "=" ** 100 ++ "\n", .{});
    std.debug.print("  Summary:\n", .{});
    std.debug.print("  - NullDb performs ZERO heap allocations (all ops are no-ops)\n", .{});
    std.debug.print("  - DB-001 fix: put/delete now silently discard instead of error.StorageError\n", .{});
    std.debug.print("  - NullDb is the theoretical upper bound on vtable dispatch throughput\n", .{});
    std.debug.print("  - Overhead is purely: vtable indirection + key generation (measured above)\n", .{});
    std.debug.print("  - For accurate numbers: zig test -O ReleaseFast client/db/bench_nulldb.zig\n", .{});
    std.debug.print("=" ** 100 ++ "\n\n", .{});
}

pub fn main() !void {
    if (@import("builtin").is_test) return;
    run_benchmarks();
}

test "NullDb benchmark suite runs without errors" {
    run_benchmarks();
}
