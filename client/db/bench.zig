/// Benchmarks for the Database Abstraction Layer (DB-001).
///
/// Measures throughput and latency for:
///   1. MemoryDatabase put/get (sequential and random access)
///   2. MemoryDatabase mixed read/write workloads (block processing)
///   3. ReadOnlyDb strict mode reads (vtable overhead, DB-001 fix)
///   4. ReadOnlyDb overlay writes and reads (snapshot execution pattern)
///   5. ReadOnlyDb clear_temp_changes cycle (ClearTempChanges pattern)
///   6. Factory creation overhead (MemDbFactory, NullDbFactory, ReadOnlyDbFactory)
///   7. WriteBatch accumulate + commit
///   8. Vtable dispatch overhead (direct vs interface)
///   9. Memory usage and arena allocation patterns
///  10. Simulated block state operations
///
/// Run:
///   zig build bench-db                         # Debug mode
///   zig build bench-db -Doptimize=ReleaseFast  # Release mode (accurate numbers)
///
/// Target: Nethermind processes ~700 MGas/s. The DB layer must handle
/// ~2400+ storage operations per block at negligible overhead compared to EVM.
const std = @import("std");
const bench_utils = @import("bench_utils");
const print_result = bench_utils.print_result;
const format_ns = bench_utils.format_ns;

// Sibling module imports (resolved via root_source_file relative path).
const adapter = @import("adapter.zig");
const memory = @import("memory.zig");
const read_only = @import("read_only.zig");
const factory_mod = @import("factory.zig");
const rocksdb = @import("rocksdb.zig");

const Database = adapter.Database;
const DbValue = adapter.DbValue;
const Error = adapter.Error;
const WriteBatch = adapter.WriteBatch;
const MemoryDatabase = memory.MemoryDatabase;
const ReadOnlyDb = read_only.ReadOnlyDb;
const MemDbFactory = factory_mod.MemDbFactory;
const NullDbFactory = factory_mod.NullDbFactory;
const ReadOnlyDbFactory = factory_mod.ReadOnlyDbFactory;
const DbSettings = rocksdb.DbSettings;

/// Number of warmup iterations before timing.
const WARMUP_ITERS: usize = 3;
/// Number of timed iterations to average.
const BENCH_ITERS: usize = 10;

/// Tier sizes.
const SMALL_N: usize = 1_000;
const MEDIUM_N: usize = 10_000;
const LARGE_N: usize = 100_000;

// ============================================================================
// Key/value generation helpers
// ============================================================================

/// Generate a deterministic 32-byte key from an index.
/// Simulates Ethereum storage keys (32-byte slot hashes).
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

/// Helper: format a BenchResult from raw values.
fn result(name: []const u8, ops: usize, elapsed_ns: u64) bench_utils.BenchResult {
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

// ============================================================================
// Benchmark implementations
// ============================================================================

/// Benchmark: Sequential insert — put N 32-byte keys into a fresh MemoryDatabase.
fn bench_sequential_insert(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var db = MemoryDatabase.init(std.heap.page_allocator, .state);
        for (0..n) |i| {
            db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
        }
        db.deinit();
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var db = MemoryDatabase.init(std.heap.page_allocator, .state);
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
        }
        total_ns += timer.read();
        db.deinit();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: Random read — get N keys from a pre-populated database.
fn bench_random_read(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    for (0..n) |i| {
        db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
    }

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var idx: usize = 0;
        for (0..n) |_| {
            idx = (idx *% 6364136223846793005 +% 1442695040888963407) % n;
            const val = db.get(make_key(&key_buf, idx));
            if (val) |v| v.release();
        }
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var idx: usize = 0;
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |_| {
            idx = (idx *% 6364136223846793005 +% 1442695040888963407) % n;
            const val = db.get(make_key(&key_buf, idx));
            if (val) |v| v.release();
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: Mixed read/write (80% reads, 20% writes).
fn bench_mixed_rw(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    for (0..n / 2) |i| {
        db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
    }

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            if (i % 5 == 0) {
                db.put(make_key(&key_buf, n + i), make_value(&val_buf, i)) catch unreachable;
            } else {
                const val = db.get(make_key(&key_buf, i % (n / 2)));
                if (val) |v| v.release();
            }
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: Vtable dispatch overhead — direct call vs vtable call.
fn bench_vtable_overhead(n: usize) struct { direct_ns: u64, vtable_ns: u64 } {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    for (0..1000) |i| {
        db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
    }
    const iface = db.database();

    // Direct
    var direct_total: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            const val = db.get(make_key(&key_buf, i % 1000));
            if (val) |v| v.release();
        }
        direct_total += timer.read();
    }

    // Vtable
    var vtable_total: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            const val = iface.get(make_key(&key_buf, i % 1000)) catch unreachable;
            if (val) |v| v.release();
        }
        vtable_total += timer.read();
    }

    return .{
        .direct_ns = direct_total / BENCH_ITERS,
        .vtable_ns = vtable_total / BENCH_ITERS,
    };
}

/// Benchmark: ReadOnlyDb strict mode — reads through read-only wrapper (DB-001 fix).
fn bench_readonly_strict_reads(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    for (0..1000) |i| {
        db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
    }

    var ro = ReadOnlyDb.init(db.database());
    defer ro.deinit();
    const iface = ro.database();

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            const val = iface.get(make_key(&key_buf, i % 1000)) catch unreachable;
            if (val) |v| v.release();
        }
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: ReadOnlyDb overlay writes + reads (snapshot execution pattern).
fn bench_readonly_overlay(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    for (0..500) |i| {
        db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
    }

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();

        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            iface.put(make_key(&key_buf, 1000 + i), make_value(&val_buf, i)) catch unreachable;
        }
        for (0..n) |i| {
            if (i % 2 == 0) {
                const val = iface.get(make_key(&key_buf, 1000 + (i % n))) catch unreachable;
                if (val) |v| v.release();
            } else {
                const val = iface.get(make_key(&key_buf, i % 500)) catch unreachable;
                if (val) |v| v.release();
            }
        }
        total_ns += timer.read();
        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: ReadOnlyDb clear_temp_changes cycle (ClearTempChanges pattern).
fn bench_overlay_clear_cycle(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    for (0..100) |i| {
        db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
    }

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();

        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |cycle| {
            for (0..10) |i| {
                iface.put(make_key(&key_buf, 1000 + cycle * 10 + i), make_value(&val_buf, i)) catch unreachable;
            }
            for (0..10) |i| {
                const val = iface.get(make_key(&key_buf, 1000 + cycle * 10 + i)) catch unreachable;
                if (val) |v| v.release();
            }
            ro.clear_temp_changes();
        }
        total_ns += timer.read();
        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: Factory creation overhead.
fn bench_factory_creation(n: usize) struct { mem_ns: u64, null_ns: u64, ro_overlay_ns: u64, ro_strict_ns: u64 } {
    // MemDbFactory
    var mem_total: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var mem_factory = MemDbFactory.init(std.heap.page_allocator);
        const f = mem_factory.factory();
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |_| {
            const owned = f.createDb(DbSettings.init(.state, "state")) catch unreachable;
            owned.deinit();
        }
        mem_total += timer.read();
        mem_factory.deinit();
    }

    // NullDbFactory
    var null_total: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var null_factory = NullDbFactory.init();
        const f = null_factory.factory();
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |_| {
            _ = f.createDb(DbSettings.init(.state, "state")) catch |err| switch (err) {
                error.UnsupportedOperation => {}, // NullDbFactory always returns this
                else => unreachable,
            };
        }
        null_total += timer.read();
        null_factory.deinit();
    }

    // ReadOnlyDbFactory (overlay)
    var ro_overlay_total: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var mem_factory = MemDbFactory.init(std.heap.page_allocator);
        var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.heap.page_allocator, false);
        const f = ro_factory.factory();
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |_| {
            const owned = f.createDb(DbSettings.init(.state, "state")) catch unreachable;
            owned.deinit();
        }
        ro_overlay_total += timer.read();
        ro_factory.deinit();
        mem_factory.deinit();
    }

    // ReadOnlyDbFactory (strict — DB-001 fix target)
    var ro_strict_total: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var mem_factory = MemDbFactory.init(std.heap.page_allocator);
        var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.heap.page_allocator, true);
        const f = ro_factory.factory();
        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |_| {
            const owned = f.createDb(DbSettings.init(.state, "state")) catch unreachable;
            owned.deinit();
        }
        ro_strict_total += timer.read();
        ro_factory.deinit();
        mem_factory.deinit();
    }

    return .{
        .mem_ns = mem_total / BENCH_ITERS,
        .null_ns = null_total / BENCH_ITERS,
        .ro_overlay_ns = ro_overlay_total / BENCH_ITERS,
        .ro_strict_ns = ro_strict_total / BENCH_ITERS,
    };
}

/// Benchmark: WriteBatch accumulate + commit.
fn bench_write_batch(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var db = MemoryDatabase.init(std.heap.page_allocator, .state);
        const iface = db.database();
        var batch = WriteBatch.init(std.heap.page_allocator, iface);

        var timer = std.time.Timer.start() catch unreachable;
        for (0..n) |i| {
            batch.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
        }
        batch.commit() catch unreachable;
        total_ns += timer.read();

        batch.deinit();
        db.deinit();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: Memory usage — peak allocation for N inserts.
fn bench_memory_usage(n: usize) struct { elapsed_ns: u64, peak_bytes: usize } {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    var db = MemoryDatabase.init(arena.allocator(), .state);

    var timer = std.time.Timer.start() catch unreachable;
    for (0..n) |i| {
        db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
    }
    const elapsed = timer.read();
    const total_allocated = gpa.total_requested_bytes;
    arena.deinit();

    return .{ .elapsed_ns = elapsed, .peak_bytes = total_allocated };
}

/// Benchmark: Arena-scoped DB pattern (create + populate + destroy).
fn bench_arena_db_cycle(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var db = MemoryDatabase.init(arena.allocator(), .state);
        for (0..n) |i| {
            db.put(make_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
        }
        for (0..n) |i| {
            const val = db.get(make_key(&key_buf, i));
            if (val) |v| v.release();
        }
        arena.deinit();
        total_ns += timer.read();
    }
    return total_ns / BENCH_ITERS;
}

/// Benchmark: Simulated block state operations.
/// 200 txs × (2 account reads + 5 storage writes + 5 storage reads) = 2400 ops.
fn bench_block_state_ops() u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    const txs_per_block: usize = 200;
    const storage_writes_per_tx: usize = 5;
    const storage_reads_per_tx: usize = 5;
    const account_reads_per_tx: usize = 2;

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var db = MemoryDatabase.init(std.heap.page_allocator, .state);
        var timer = std.time.Timer.start() catch unreachable;
        for (0..txs_per_block) |tx| {
            for (0..account_reads_per_tx) |a| {
                const val = db.get(make_key(&key_buf, tx * 100 + a));
                if (val) |v| v.release();
            }
            for (0..storage_writes_per_tx) |s| {
                db.put(make_key(&key_buf, tx * 100 + 10 + s), make_value(&val_buf, tx * s)) catch unreachable;
            }
            for (0..storage_reads_per_tx) |s| {
                const val = db.get(make_key(&key_buf, tx * 100 + 10 + s));
                if (val) |v| v.release();
            }
        }
        total_ns += timer.read();
        db.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// Main benchmark entry point
// ============================================================================

pub fn main() !void {
    if (@import("builtin").is_test) return;
    std.debug.print("\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
    std.debug.print("  Guillotine DB Abstraction Layer Benchmarks (DB-001)\n", .{});
    std.debug.print("  Key size: 32 bytes, Value size: 32 bytes (simulating Ethereum storage slots)\n", .{});
    std.debug.print("  Warmup: {d} iters, Timed: {d} iters (averaged)\n", .{ WARMUP_ITERS, BENCH_ITERS });
    std.debug.print("=" ** 100 ++ "\n\n", .{});

    // -- Sequential Insert --
    std.debug.print("--- MemoryDatabase: Sequential Insert ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "insert (1K keys, 32B each)" },
        .{ .n = MEDIUM_N, .name = "insert (10K keys, 32B each)" },
        .{ .n = LARGE_N, .name = "insert (100K keys, 32B each)" },
    }) |s| {
        print_result(result(s.name, s.n, bench_sequential_insert(s.n)));
    }
    std.debug.print("\n", .{});

    // -- Random Read --
    std.debug.print("--- MemoryDatabase: Random Read ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "random read (1K lookups)" },
        .{ .n = MEDIUM_N, .name = "random read (10K lookups)" },
        .{ .n = LARGE_N, .name = "random read (100K lookups)" },
    }) |s| {
        print_result(result(s.name, s.n, bench_random_read(s.n)));
    }
    std.debug.print("\n", .{});

    // -- Mixed Read/Write --
    std.debug.print("--- MemoryDatabase: Mixed Read/Write (80/20) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "mixed r/w (1K ops)" },
        .{ .n = MEDIUM_N, .name = "mixed r/w (10K ops)" },
        .{ .n = LARGE_N, .name = "mixed r/w (100K ops)" },
    }) |s| {
        print_result(result(s.name, s.n, bench_mixed_rw(s.n)));
    }
    std.debug.print("\n", .{});

    // -- Vtable Dispatch Overhead --
    std.debug.print("--- Vtable Dispatch Overhead (direct vs interface) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = MEDIUM_N, .name = "vtable overhead (10K reads)" },
        .{ .n = LARGE_N, .name = "vtable overhead (100K reads)" },
    }) |s| {
        const r = bench_vtable_overhead(s.n);
        const direct_per_op = if (s.n > 0) r.direct_ns / s.n else 0;
        const vtable_per_op = if (s.n > 0) r.vtable_ns / s.n else 0;
        const overhead_pct = if (r.direct_ns > 0)
            (@as(f64, @floatFromInt(r.vtable_ns)) / @as(f64, @floatFromInt(r.direct_ns)) - 1.0) * 100.0
        else
            0.0;
        std.debug.print("  {s:<55} direct={s}  vtable={s}  overhead={d:.1}%%\n", .{
            s.name,
            &format_ns(direct_per_op),
            &format_ns(vtable_per_op),
            overhead_pct,
        });
    }
    std.debug.print("\n", .{});

    // -- ReadOnlyDb Strict Mode (DB-001 fix) --
    std.debug.print("--- ReadOnlyDb: Strict Mode Reads (DB-001 fix) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = MEDIUM_N, .name = "strict readonly read (10K lookups)" },
        .{ .n = LARGE_N, .name = "strict readonly read (100K lookups)" },
    }) |s| {
        print_result(result(s.name, s.n, bench_readonly_strict_reads(s.n)));
    }
    std.debug.print("\n", .{});

    // -- ReadOnlyDb Overlay --
    std.debug.print("--- ReadOnlyDb: Overlay Write+Read ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "overlay w+r (1K ops each)" },
        .{ .n = MEDIUM_N, .name = "overlay w+r (10K ops each)" },
    }) |s| {
        print_result(result(s.name, s.n * 2, bench_readonly_overlay(s.n)));
    }
    std.debug.print("\n", .{});

    // -- ReadOnlyDb Clear Cycle --
    std.debug.print("--- ReadOnlyDb: Overlay Clear Cycle (ClearTempChanges) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = 100, .name = "clear cycle (100 cycles)" },
        .{ .n = SMALL_N, .name = "clear cycle (1K cycles)" },
        .{ .n = 5_000, .name = "clear cycle (5K cycles)" },
    }) |s| {
        print_result(result(s.name, s.n, bench_overlay_clear_cycle(s.n)));
    }
    std.debug.print("\n", .{});

    // -- Factory Creation (DB-001 focus) --
    std.debug.print("--- Factory Creation Overhead (DB-001) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = 100, .name = "factory create+deinit (100 DBs)" },
        .{ .n = SMALL_N, .name = "factory create+deinit (1K DBs)" },
    }) |s| {
        const r = bench_factory_creation(s.n);
        const mem_per = if (s.n > 0) r.mem_ns / s.n else 0;
        const null_per = if (s.n > 0) r.null_ns / s.n else 0;
        const ro_ov_per = if (s.n > 0) r.ro_overlay_ns / s.n else 0;
        const ro_st_per = if (s.n > 0) r.ro_strict_ns / s.n else 0;
        std.debug.print("  {s}\n", .{s.name});
        std.debug.print("    MemDbFactory:           {s}/op\n", .{&format_ns(mem_per)});
        std.debug.print("    NullDbFactory:          {s}/op\n", .{&format_ns(null_per)});
        std.debug.print("    ReadOnlyFactory(over):  {s}/op\n", .{&format_ns(ro_ov_per)});
        std.debug.print("    ReadOnlyFactory(strict):{s}/op  <-- DB-001 fix\n", .{&format_ns(ro_st_per)});
    }
    std.debug.print("\n", .{});

    // -- WriteBatch --
    std.debug.print("--- WriteBatch: Accumulate + Commit ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "batch commit (1K ops)" },
        .{ .n = MEDIUM_N, .name = "batch commit (10K ops)" },
    }) |s| {
        print_result(result(s.name, s.n, bench_write_batch(s.n)));
    }
    std.debug.print("\n", .{});

    // -- Arena DB Cycle --
    std.debug.print("--- Arena DB Pattern (tx-scoped create+populate+destroy) ---\n", .{});
    for ([_]struct { n: usize, name: []const u8 }{
        .{ .n = SMALL_N, .name = "arena cycle (1K insert+read+free)" },
        .{ .n = MEDIUM_N, .name = "arena cycle (10K insert+read+free)" },
    }) |s| {
        print_result(result(s.name, s.n * 2, bench_arena_db_cycle(s.n)));
    }
    std.debug.print("\n", .{});

    // -- Memory Usage --
    std.debug.print("--- Memory Usage (arena-backed MemoryDatabase) ---\n", .{});
    for ([_]usize{ 100, 1_000, 10_000, 100_000 }) |n| {
        const r = bench_memory_usage(n);
        const bytes_per_entry = if (n > 0) r.peak_bytes / n else 0;
        const theoretical_min: usize = 80 * n; // 32 key + 32 value + ~16 hashmap overhead
        const overhead_pct = if (theoretical_min > 0)
            (@as(f64, @floatFromInt(r.peak_bytes)) / @as(f64, @floatFromInt(theoretical_min)) - 1.0) * 100.0
        else
            0.0;
        std.debug.print("  {d:>8} entries: {d:>10} bytes ({d} bytes/entry, {d:.1}%% overhead vs ~80B theoretical)\n", .{
            n, r.peak_bytes, bytes_per_entry, overhead_pct,
        });
    }
    std.debug.print("\n", .{});

    // -- Block Processing Simulation --
    std.debug.print("--- Block State Operations Simulation ---\n", .{});
    std.debug.print("  (200 txs/block, 2 account reads + 5 storage writes + 5 storage reads per tx)\n", .{});
    {
        const elapsed = bench_block_state_ops();
        const elapsed_str = format_ns(elapsed);
        const blocks_per_sec = if (elapsed > 0)
            1_000_000_000.0 / @as(f64, @floatFromInt(elapsed))
        else
            0.0;
        const ops_per_block: usize = 200 * (2 + 5 + 5);
        const ops_per_sec = blocks_per_sec * @as(f64, @floatFromInt(ops_per_block));

        std.debug.print("  Block DB time:              {s}\n", .{&elapsed_str});
        std.debug.print("  Block throughput (DB):       {d:.0} blocks/s\n", .{blocks_per_sec});
        std.debug.print("  DB ops/block:                ~{d}\n", .{ops_per_block});
        std.debug.print("  DB ops/sec:                  {d:.0} ({d:.2} M ops/s)\n", .{ ops_per_sec, ops_per_sec / 1e6 });
    }
    std.debug.print("\n", .{});

    // -- Throughput Analysis --
    std.debug.print("--- Throughput Analysis vs Nethermind Target ---\n", .{});
    {
        const block_elapsed = bench_block_state_ops();
        const blocks_per_sec = if (block_elapsed > 0)
            1_000_000_000.0 / @as(f64, @floatFromInt(block_elapsed))
        else
            0.0;
        const effective_mgas = blocks_per_sec * 30.0; // 30M gas/block post-merge

        std.debug.print("  Block DB time:                {s}\n", .{&format_ns(block_elapsed)});
        std.debug.print("  Block throughput (DB):         {d:.0} blocks/s\n", .{blocks_per_sec});
        std.debug.print("  Effective MGas/s (DB only):    {d:.0} MGas/s\n", .{effective_mgas});
        std.debug.print("  Nethermind target:             700 MGas/s (full client)\n", .{});
        std.debug.print("  Required blocks/s for target:  ~23 blocks/s (30M gas/block)\n", .{});

        const comfortable = blocks_per_sec >= 2300.0;
        const meets_target = blocks_per_sec >= 23.0;

        if (comfortable) {
            std.debug.print("  Status: PASS - negligible DB overhead (<1%% of budget)\n", .{});
        } else if (meets_target) {
            std.debug.print("  Status: PASS - meets target but DB overhead notable\n", .{});
        } else {
            std.debug.print("  Status: FAIL - DB layer alone cannot keep up!\n", .{});
        }
    }

    std.debug.print("\n" ++ "=" ** 100 ++ "\n", .{});
    std.debug.print("  Notes:\n", .{});
    std.debug.print("  - MemoryDatabase uses ArenaAllocator (all freed at tx end)\n", .{});
    std.debug.print("  - No heap allocations in hot read path (get returns borrowed slice)\n", .{});
    std.debug.print("  - ReadOnlyDb strict mode: zero extra allocation (no overlay) — DB-001 fix\n", .{});
    std.debug.print("  - ReadOnlyDb overlay mode: writes buffered in separate MemoryDatabase\n", .{});
    std.debug.print("  - For accurate numbers: zig build bench-db -Doptimize=ReleaseFast\n", .{});
    std.debug.print("=" ** 100 ++ "\n\n", .{});
}

test "bench main entrypoint" {
    try main();
}
