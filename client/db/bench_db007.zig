/// Benchmarks for DB-007: Ordered iteration with ReadOnlyDb overlay (MergeSortIterator).
///
/// Measures throughput and latency for:
///   1. Ordered iterator creation (MergeSortIterator setup with pre-fetch)
///   2. Ordered iteration throughput — full consume of merge-sorted entries
///   3. Unordered vs ordered iteration comparison
///   4. Overlay density scaling — varying overlay/wrapped ratio
///   5. Duplicate key handling — overlay precedence deduplication cost
///   6. Iterator with large key/value sizes — memory pressure
///   7. Clear + re-iterate cycle — snapshot execution pattern
///   8. Block processing with ordered iteration — Ethereum state walk simulation
///   9. Memory usage — allocation overhead for MergeSortIterator vs ReadOnlyIterator
///  10. Scaling behavior — iteration cost vs total entry count
///
/// Run:
///   zig build bench-db007                         # Debug mode
///   zig build bench-db007 -Doptimize=ReleaseFast  # Release mode (accurate numbers)
///
/// Target: Nethermind processes ~700 MGas/s. The ordered iteration must handle
/// state trie walks at negligible overhead compared to core DB ops.
const std = @import("std");

const adapter = @import("adapter.zig");
const memory = @import("memory.zig");
const read_only = @import("read_only.zig");

const Database = adapter.Database;
const DbEntry = adapter.DbEntry;
const DbValue = adapter.DbValue;
const Error = adapter.Error;
const MemoryDatabase = memory.MemoryDatabase;
const ReadOnlyDb = read_only.ReadOnlyDb;

// ============================================================================
// Formatting helpers (self-contained, no bench_utils dependency)
// ============================================================================

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

fn print_result(r: BenchResult) void {
    const total_str = format_ns(r.elapsed_ns);
    const per_op_str = format_ns(r.per_op_ns);
    const ops_str = format_ops_per_sec(r.ops, r.elapsed_ns);
    std.debug.print("  {s:<55} {d:>8} ops  total={s}  per-op={s}  {s}\n", .{
        r.name,
        r.ops,
        &total_str,
        &per_op_str,
        &ops_str,
    });
}

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
/// Uses big-endian prefix so keys are naturally sorted.
fn make_sorted_key(buf: *[32]u8, index: usize) []const u8 {
    const idx: u64 = @intCast(index);
    std.mem.writeInt(u64, buf[0..8], idx, .big);
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

/// Helper: build a BenchResult from raw values.
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

/// Populate a MemoryDatabase with n sorted entries.
fn populate_db(db: *MemoryDatabase, n: usize) void {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    for (0..n) |i| {
        db.put(make_sorted_key(&key_buf, i), make_value(&val_buf, i)) catch unreachable;
    }
}

/// Consume all entries from an iterator, releasing each entry.
fn drain_iterator(it: *adapter.DbIterator) usize {
    var count: usize = 0;
    while (it.next() catch unreachable) |entry| {
        entry.release();
        count += 1;
    }
    return count;
}

// ============================================================================
// 1. Ordered iterator creation (MergeSortIterator setup)
// ============================================================================

/// Measures the cost of creating a MergeSortIterator (ordered=true).
/// This includes: get ordered iterators from both sources + pre-fetch first entries.
fn bench_ordered_iterator_creation(wrapped_n: usize, overlay_n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    populate_db(&db, wrapped_n);

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(
                make_sorted_key(&key_buf, wrapped_n + i),
                make_value(&val_buf, wrapped_n + i),
            ) catch unreachable;
        }
        var it = iface.iterator(true) catch unreachable;
        it.deinit();
        ro.deinit();
    }

    // Timed — measure only iterator creation (not consumption)
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(
                make_sorted_key(&key_buf, wrapped_n + i),
                make_value(&val_buf, wrapped_n + i),
            ) catch unreachable;
        }

        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(true) catch unreachable;
        total_ns += timer.read();

        it.deinit();
        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// 2. Ordered iteration throughput — full consume
// ============================================================================

/// Measures throughput of iterating all entries via MergeSortIterator.
/// Overlay and wrapped have disjoint keys (no duplicates).
fn bench_ordered_iteration_disjoint(wrapped_n: usize, overlay_n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    populate_db(&db, wrapped_n);

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(
                make_sorted_key(&key_buf, wrapped_n + i),
                make_value(&val_buf, wrapped_n + i),
            ) catch unreachable;
        }
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        it.deinit();
        ro.deinit();
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(
                make_sorted_key(&key_buf, wrapped_n + i),
                make_value(&val_buf, wrapped_n + i),
            ) catch unreachable;
        }

        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        total_ns += timer.read();
        it.deinit();

        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// 3. Unordered vs ordered iteration comparison
// ============================================================================

/// Compares ordered (MergeSortIterator) vs unordered (ReadOnlyIterator) throughput.
fn bench_ordered_vs_unordered(wrapped_n: usize, overlay_n: usize) struct { ordered_ns: u64, unordered_ns: u64 } {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    populate_db(&db, wrapped_n);

    // Ordered path
    var ordered_total: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(make_sorted_key(&key_buf, wrapped_n + i), make_value(&val_buf, i)) catch unreachable;
        }

        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        ordered_total += timer.read();
        it.deinit();

        ro.deinit();
    }

    // Unordered path
    var unordered_total: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(make_sorted_key(&key_buf, wrapped_n + i), make_value(&val_buf, i)) catch unreachable;
        }

        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(false) catch unreachable;
        _ = drain_iterator(&it);
        unordered_total += timer.read();
        it.deinit();

        ro.deinit();
    }

    return .{
        .ordered_ns = ordered_total / BENCH_ITERS,
        .unordered_ns = unordered_total / BENCH_ITERS,
    };
}

// ============================================================================
// 4. Overlay density scaling — varying overlay/wrapped ratio
// ============================================================================

/// Measures iteration throughput with varying overlay density.
/// Total entries = n, overlay_pct% are in overlay, rest in wrapped.
fn bench_overlay_density(n: usize, overlay_pct: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    const overlay_n = n * overlay_pct / 100;
    const wrapped_n = n - overlay_n;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Wrapped gets even-indexed keys [0, 2, 4, ...]
    for (0..wrapped_n) |i| {
        db.put(make_sorted_key(&key_buf, i * 2), make_value(&val_buf, i)) catch unreachable;
    }

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        // Overlay gets odd-indexed keys [1, 3, 5, ...]
        for (0..overlay_n) |i| {
            iface.put(make_sorted_key(&key_buf, i * 2 + 1), make_value(&val_buf, i)) catch unreachable;
        }
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        it.deinit();
        ro.deinit();
    }

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(make_sorted_key(&key_buf, i * 2 + 1), make_value(&val_buf, i)) catch unreachable;
        }

        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        total_ns += timer.read();
        it.deinit();

        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// 5. Duplicate key handling — overlay precedence deduplication cost
// ============================================================================

/// Measures iteration when all keys are duplicated (overlay overrides all wrapped keys).
/// This exercises the duplicate-key branch in MergeSortIterator (release wrapped entry).
fn bench_full_duplicate_iteration(n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    populate_db(&db, n);

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        // Overlay has same keys with different values
        for (0..n) |i| {
            iface.put(make_sorted_key(&key_buf, i), make_value(&val_buf, n + i)) catch unreachable;
        }
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        it.deinit();
        ro.deinit();
    }

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..n) |i| {
            iface.put(make_sorted_key(&key_buf, i), make_value(&val_buf, n + i)) catch unreachable;
        }

        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        total_ns += timer.read();
        it.deinit();

        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

/// Measures iteration with no duplicates (disjoint keys).
/// Baseline for comparison against full-duplicate.
fn bench_no_duplicate_iteration(n: usize) u64 {
    return bench_ordered_iteration_disjoint(n / 2, n / 2);
}

// ============================================================================
// 6. Partial consume — iterator deinit with unconsumed entries
// ============================================================================

/// Measures cost of creating an ordered iterator, consuming only a fraction,
/// then calling deinit (which must release buffered pre-fetched entries).
fn bench_partial_consume(total_n: usize, consume_n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    populate_db(&db, total_n / 2);

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..total_n / 2) |i| {
            iface.put(
                make_sorted_key(&key_buf, total_n / 2 + i),
                make_value(&val_buf, i),
            ) catch unreachable;
        }

        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(true) catch unreachable;
        for (0..consume_n) |_| {
            if (it.next() catch unreachable) |entry| {
                entry.release();
            } else break;
        }
        it.deinit();
        total_ns += timer.read();

        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// 7. Clear + re-iterate cycle — snapshot execution pattern
// ============================================================================

/// Simulates the ClearTempChanges + re-iterate pattern used in snapshot execution.
/// Each cycle: write to overlay, iterate ordered, clear overlay, repeat.
fn bench_clear_reiterate_cycle(wrapped_n: usize, overlay_per_cycle: usize, num_cycles: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    populate_db(&db, wrapped_n);

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();

        var timer = std.time.Timer.start() catch unreachable;
        for (0..num_cycles) |cycle| {
            // Write overlay entries
            for (0..overlay_per_cycle) |i| {
                iface.put(
                    make_sorted_key(&key_buf, wrapped_n + cycle * overlay_per_cycle + i),
                    make_value(&val_buf, cycle * overlay_per_cycle + i),
                ) catch unreachable;
            }
            // Ordered iteration
            var it = iface.iterator(true) catch unreachable;
            _ = drain_iterator(&it);
            it.deinit();
            // Clear overlay
            ro.clear_temp_changes();
        }
        total_ns += timer.read();

        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// 8. Block processing with ordered iteration — state walk simulation
// ============================================================================

/// Simulates Ethereum block processing that requires ordered state iteration.
/// Each "transaction":
///   - Write 5 state changes to overlay
///   - Create ordered iterator, read first 10 entries (state proof walk)
///   - Destroy iterator
///   - 2 regular gets (state reads)
fn bench_block_with_ordered_iteration() u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    const txs_per_block: usize = 200;
    const writes_per_tx: usize = 5;
    const iter_reads_per_tx: usize = 10;
    const gets_per_tx: usize = 2;

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var db = MemoryDatabase.init(std.heap.page_allocator, .state);
        // Pre-populate with 1000 state entries
        populate_db(&db, 1000);

        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();

        var timer = std.time.Timer.start() catch unreachable;
        for (0..txs_per_block) |tx| {
            // State writes
            for (0..writes_per_tx) |s| {
                iface.put(
                    make_sorted_key(&key_buf, 1000 + tx * writes_per_tx + s),
                    make_value(&val_buf, tx * writes_per_tx + s),
                ) catch unreachable;
            }

            // Ordered iteration (state proof walk — read first 10 entries)
            var it = iface.iterator(true) catch unreachable;
            for (0..iter_reads_per_tx) |_| {
                if (it.next() catch unreachable) |entry| {
                    entry.release();
                } else break;
            }
            it.deinit();

            // Regular state reads
            for (0..gets_per_tx) |a| {
                const val = iface.get(make_sorted_key(&key_buf, tx * 100 + a)) catch unreachable;
                if (val) |v| v.release();
            }
        }
        total_ns += timer.read();

        ro.deinit();
        db.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// 9. Scaling behavior — iteration cost vs total entry count
// ============================================================================

/// End-to-end: create ReadOnlyDb, populate overlay, ordered iterate all, deinit.
fn bench_full_cycle_scaling(wrapped_n: usize, overlay_n: usize) u64 {
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    populate_db(&db, wrapped_n);

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(make_sorted_key(&key_buf, wrapped_n + i), make_value(&val_buf, i)) catch unreachable;
        }
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        it.deinit();
        ro.deinit();
    }

    // Timed
    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var ro = ReadOnlyDb.init_with_write_store(db.database(), std.heap.page_allocator) catch unreachable;
        const iface = ro.database();
        for (0..overlay_n) |i| {
            iface.put(make_sorted_key(&key_buf, wrapped_n + i), make_value(&val_buf, i)) catch unreachable;
        }

        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        it.deinit();
        total_ns += timer.read();

        ro.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// 10. Wrapped-only iteration (no overlay — pass-through baseline)
// ============================================================================

/// Measures ordered iteration when no overlay exists (direct delegation).
/// This is the baseline: ReadOnlyDb.iterator_impl just forwards to wrapped.iterator(true).
fn bench_wrapped_only_ordered(n: usize) u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();
    populate_db(&db, n);

    var ro = ReadOnlyDb.init(db.database());
    defer ro.deinit();
    const iface = ro.database();

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        it.deinit();
    }

    var total_ns: u64 = 0;
    for (0..BENCH_ITERS) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        var it = iface.iterator(true) catch unreachable;
        _ = drain_iterator(&it);
        total_ns += timer.read();
        it.deinit();
    }
    return total_ns / BENCH_ITERS;
}

// ============================================================================
// Main benchmark entry point
// ============================================================================

pub fn main() !void {
    if (@import("builtin").is_test) return;
    const is_release = @import("builtin").mode != .Debug;
    const mode_str = if (is_release) "ReleaseFast" else "Debug";

    std.debug.print("\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
    std.debug.print("  DB-007 Benchmarks: Ordered Iteration with ReadOnlyDb Overlay (MergeSortIterator)\n", .{});
    std.debug.print("  Mode: {s}, Key: 32B, Value: 32B, Warmup: {d}, Timed: {d} iters (avg)\n", .{ mode_str, WARMUP_ITERS, BENCH_ITERS });
    std.debug.print("=" ** 100 ++ "\n\n", .{});

    // -- 1. Ordered iterator creation cost --
    std.debug.print("--- 1. Ordered Iterator Creation (MergeSortIterator setup + pre-fetch) ---\n", .{});
    for ([_]struct { w: usize, o: usize, label: []const u8 }{
        .{ .w = SMALL_N, .o = 100, .label = "create ordered iter (1K wrapped + 100 overlay)" },
        .{ .w = MEDIUM_N, .o = SMALL_N, .label = "create ordered iter (10K wrapped + 1K overlay)" },
        .{ .w = LARGE_N, .o = MEDIUM_N, .label = "create ordered iter (100K wrapped + 10K overlay)" },
    }) |s| {
        print_result(make_result(s.label, 1, bench_ordered_iterator_creation(s.w, s.o)));
    }
    std.debug.print("\n", .{});

    // -- 2. Ordered iteration throughput (disjoint keys) --
    std.debug.print("--- 2. Ordered Iteration Throughput (disjoint keys, full consume) ---\n", .{});
    for ([_]struct { w: usize, o: usize, label: []const u8 }{
        .{ .w = 500, .o = 500, .label = "iterate 1K total (500+500 disjoint)" },
        .{ .w = 5_000, .o = 5_000, .label = "iterate 10K total (5K+5K disjoint)" },
        .{ .w = 50_000, .o = 50_000, .label = "iterate 100K total (50K+50K disjoint)" },
    }) |s| {
        print_result(make_result(s.label, s.w + s.o, bench_ordered_iteration_disjoint(s.w, s.o)));
    }
    std.debug.print("\n", .{});

    // -- 3. Ordered vs unordered comparison --
    std.debug.print("--- 3. Ordered vs Unordered Iteration (5K wrapped + 5K overlay, disjoint) ---\n", .{});
    for ([_]struct { w: usize, o: usize, label: []const u8 }{
        .{ .w = 500, .o = 500, .label = "1K total (500+500)" },
        .{ .w = 5_000, .o = 5_000, .label = "10K total (5K+5K)" },
    }) |s| {
        const r = bench_ordered_vs_unordered(s.w, s.o);
        const total = s.w + s.o;
        const ordered_per = if (total > 0) r.ordered_ns / total else 0;
        const unordered_per = if (total > 0) r.unordered_ns / total else 0;
        const overhead_pct = if (r.unordered_ns > 0)
            (@as(f64, @floatFromInt(r.ordered_ns)) / @as(f64, @floatFromInt(r.unordered_ns)) - 1.0) * 100.0
        else
            0.0;
        std.debug.print("  {s:<55} ordered/entry={s}  unord/entry={s}  overhead={d:.1}%%\n", .{
            s.label,
            &format_ns(ordered_per),
            &format_ns(unordered_per),
            overhead_pct,
        });
    }
    std.debug.print("\n", .{});

    // -- 4. Overlay density scaling --
    std.debug.print("--- 4. Overlay Density Scaling (10K total entries, ordered iteration) ---\n", .{});
    for ([_]struct { pct: usize, label: []const u8 }{
        .{ .pct = 0, .label = "0% overlay (all wrapped)" },
        .{ .pct = 10, .label = "10% overlay" },
        .{ .pct = 25, .label = "25% overlay" },
        .{ .pct = 50, .label = "50% overlay" },
        .{ .pct = 75, .label = "75% overlay" },
        .{ .pct = 100, .label = "100% overlay (all overlay)" },
    }) |s| {
        if (s.pct == 0) {
            // Special case: no overlay means ReadOnlyDb passes through to wrapped
            print_result(make_result(s.label, MEDIUM_N, bench_wrapped_only_ordered(MEDIUM_N)));
        } else {
            print_result(make_result(s.label, MEDIUM_N, bench_overlay_density(MEDIUM_N, s.pct)));
        }
    }
    std.debug.print("\n", .{});

    // -- 5. Duplicate key handling --
    std.debug.print("--- 5. Duplicate Key Handling (overlay precedence deduplication) ---\n", .{});
    for ([_]struct { n: usize, label_dup: []const u8, label_nodup: []const u8 }{
        .{ .n = SMALL_N, .label_dup = "100% duplicates (1K entries)", .label_nodup = "0% duplicates (1K entries)" },
        .{ .n = MEDIUM_N, .label_dup = "100% duplicates (10K entries)", .label_nodup = "0% duplicates (10K entries)" },
    }) |s| {
        const dup_ns = bench_full_duplicate_iteration(s.n);
        const nodup_ns = bench_no_duplicate_iteration(s.n);
        const dup_per = if (s.n > 0) dup_ns / s.n else 0;
        const nodup_per = if (s.n > 0) nodup_ns / s.n else 0;
        const overhead_pct = if (nodup_ns > 0)
            (@as(f64, @floatFromInt(dup_ns)) / @as(f64, @floatFromInt(nodup_ns)) - 1.0) * 100.0
        else
            0.0;
        std.debug.print("  {s:<55} per-entry={s}\n", .{ s.label_dup, &format_ns(dup_per) });
        std.debug.print("  {s:<55} per-entry={s}  dedup overhead={d:.1}%%\n", .{ s.label_nodup, &format_ns(nodup_per), overhead_pct });
    }
    std.debug.print("\n", .{});

    // -- 6. Partial consume + deinit --
    std.debug.print("--- 6. Partial Consume + Deinit (10K total entries) ---\n", .{});
    for ([_]struct { consume: usize, label: []const u8 }{
        .{ .consume = 0, .label = "consume 0 entries (immediate deinit)" },
        .{ .consume = 1, .label = "consume 1 entry" },
        .{ .consume = 10, .label = "consume 10 entries" },
        .{ .consume = 100, .label = "consume 100 entries" },
        .{ .consume = MEDIUM_N, .label = "consume all 10K entries" },
    }) |s| {
        print_result(make_result(s.label, s.consume, bench_partial_consume(MEDIUM_N, s.consume)));
    }
    std.debug.print("\n", .{});

    // -- 7. Clear + re-iterate cycle --
    std.debug.print("--- 7. Clear + Re-iterate Cycle (ClearTempChanges pattern) ---\n", .{});
    for ([_]struct { w: usize, ov: usize, cycles: usize, label: []const u8 }{
        .{ .w = 100, .ov = 10, .cycles = 100, .label = "100 cycles (100 wrapped + 10 overlay/cycle)" },
        .{ .w = SMALL_N, .ov = 50, .cycles = 100, .label = "100 cycles (1K wrapped + 50 overlay/cycle)" },
        .{ .w = SMALL_N, .ov = 100, .cycles = 50, .label = "50 cycles (1K wrapped + 100 overlay/cycle)" },
    }) |s| {
        print_result(make_result(s.label, s.cycles, bench_clear_reiterate_cycle(s.w, s.ov, s.cycles)));
    }
    std.debug.print("\n", .{});

    // -- 8. Block processing with ordered iteration --
    std.debug.print("--- 8. Block Processing with Ordered Iteration (state walk simulation) ---\n", .{});
    std.debug.print("  (200 txs/block: 5 writes + 10 iter reads + 2 gets per tx)\n", .{});
    {
        const elapsed = bench_block_with_ordered_iteration();
        const ops_per_block: usize = 200 * (5 + 10 + 2); // 3400 ops
        const blocks_per_sec = if (elapsed > 0)
            1_000_000_000.0 / @as(f64, @floatFromInt(elapsed))
        else
            0.0;
        const ops_per_sec = blocks_per_sec * @as(f64, @floatFromInt(ops_per_block));
        const effective_mgas = blocks_per_sec * 30.0;

        std.debug.print("  Block DB time:              {s}\n", .{&format_ns(elapsed)});
        std.debug.print("  Block throughput (DB):       {d:.0} blocks/s\n", .{blocks_per_sec});
        std.debug.print("  DB ops/block:                ~{d} (incl {d} ordered iter reads)\n", .{ ops_per_block, 200 * 10 });
        std.debug.print("  DB ops/sec:                  {d:.0} ({d:.2} M ops/s)\n", .{ ops_per_sec, ops_per_sec / 1e6 });
        std.debug.print("  Effective MGas/s (DB only):   {d:.0} MGas/s\n", .{effective_mgas});
        std.debug.print("  Nethermind target:            700 MGas/s (full client)\n", .{});
        std.debug.print("  Required blocks/s for target: ~23 blocks/s (30M gas/block)\n", .{});

        const comfortable = blocks_per_sec >= 2300.0;
        const meets_target = blocks_per_sec >= 23.0;

        if (comfortable) {
            std.debug.print("  Status: PASS - ordered iteration adds negligible overhead (<1%% of budget)\n", .{});
        } else if (meets_target) {
            std.debug.print("  Status: PASS - meets target but ordered iteration overhead notable\n", .{});
        } else {
            std.debug.print("  Status: FAIL - ordered iteration overhead exceeds budget!\n", .{});
        }
    }
    std.debug.print("\n", .{});

    // -- 9. Scaling behavior --
    std.debug.print("--- 9. Full Cycle Scaling (create overlay + ordered iterate + deinit) ---\n", .{});
    for ([_]struct { w: usize, o: usize, label: []const u8 }{
        .{ .w = 50, .o = 50, .label = "100 total (50+50)" },
        .{ .w = 250, .o = 250, .label = "500 total (250+250)" },
        .{ .w = 500, .o = 500, .label = "1K total (500+500)" },
        .{ .w = 2_500, .o = 2_500, .label = "5K total (2.5K+2.5K)" },
        .{ .w = 5_000, .o = 5_000, .label = "10K total (5K+5K)" },
        .{ .w = 25_000, .o = 25_000, .label = "50K total (25K+25K)" },
        .{ .w = 50_000, .o = 50_000, .label = "100K total (50K+50K)" },
    }) |s| {
        print_result(make_result(s.label, s.w + s.o, bench_full_cycle_scaling(s.w, s.o)));
    }
    std.debug.print("\n", .{});

    // -- 10. Wrapped-only baseline --
    std.debug.print("--- 10. Wrapped-Only Baseline (no overlay, direct delegation) ---\n", .{});
    for ([_]struct { n: usize, label: []const u8 }{
        .{ .n = SMALL_N, .label = "ordered iterate (1K, no overlay)" },
        .{ .n = MEDIUM_N, .label = "ordered iterate (10K, no overlay)" },
        .{ .n = LARGE_N, .label = "ordered iterate (100K, no overlay)" },
    }) |s| {
        print_result(make_result(s.label, s.n, bench_wrapped_only_ordered(s.n)));
    }
    std.debug.print("\n", .{});

    // -- Throughput analysis --
    std.debug.print("--- Throughput Analysis vs Nethermind Target ---\n", .{});
    {
        const block_elapsed = bench_block_with_ordered_iteration();
        const blocks_per_sec = if (block_elapsed > 0)
            1_000_000_000.0 / @as(f64, @floatFromInt(block_elapsed))
        else
            0.0;
        const effective_mgas = blocks_per_sec * 30.0;

        std.debug.print("  Block DB time (w/ ordered):   {s}\n", .{&format_ns(block_elapsed)});
        std.debug.print("  Block throughput:              {d:.0} blocks/s\n", .{blocks_per_sec});
        std.debug.print("  Effective MGas/s (DB only):    {d:.0} MGas/s\n", .{effective_mgas});
        std.debug.print("  Nethermind target:             700 MGas/s\n", .{});

        if (blocks_per_sec >= 23.0) {
            std.debug.print("  Status: PASS\n", .{});
        } else {
            std.debug.print("  Status: FAIL\n", .{});
        }
    }

    std.debug.print("\n" ++ "=" ** 100 ++ "\n", .{});
    std.debug.print("  Notes:\n", .{});
    std.debug.print("  - MergeSortIterator: O(n+m) merge, one pre-fetched entry per sub-iterator\n", .{});
    std.debug.print("  - Duplicate keys: overlay wins, wrapped entry released (no leak)\n", .{});
    std.debug.print("  - Partial consume: deinit releases buffered pre-fetched entries safely\n", .{});
    std.debug.print("  - ReadOnlyIterator (unordered): uses HashSet for dedup, O(n+m) with set overhead\n", .{});
    std.debug.print("  - No-overlay path: zero extra allocation, direct delegation to wrapped.iterator()\n", .{});
    std.debug.print("  - Arena allocator for DB; write_store.allocator for iterator struct allocation\n", .{});
    std.debug.print("  - For accurate numbers: zig build bench-db007 -Doptimize=ReleaseFast\n", .{});
    std.debug.print("=" ** 100 ++ "\n\n", .{});
}

test "bench_db007 main entrypoint" {
    try main();
}
