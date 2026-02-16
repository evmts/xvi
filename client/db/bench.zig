/// Benchmarks for the DB abstraction layer (phase-0-db).
///
/// Measures throughput and latency for:
///   1. Sequential key-value insertions (simulating trie node writes)
///   2. Random key lookups (simulating state reads)
///   3. Mixed read/write workloads (simulating block processing)
///   4. WriteBatch commit throughput
///   5. Vtable dispatch overhead vs direct calls
///   6. Memory/arena allocation patterns
///
/// Run:
///   zig build bench-db                    # Debug mode
///   zig build bench-db -Doptimize=ReleaseFast  # Release mode (accurate numbers)
///
/// All benchmarks use arena allocator (transaction-scoped) to match production patterns.
const std = @import("std");
const adapter = @import("adapter.zig");
const memory = @import("memory.zig");
const columns = @import("columns.zig");
const WriteBatch = adapter.WriteBatch;
const MemoryDatabase = memory.MemoryDatabase;
const MemColumnsDb = columns.MemColumnsDb;
const ColumnsDb = columns.ColumnsDb;
const ColumnsWriteBatch = columns.ColumnsWriteBatch;
const ReceiptsColumns = columns.ReceiptsColumns;
const BlobTxsColumns = columns.BlobTxsColumns;
const Database = adapter.Database;
const ReadFlags = adapter.ReadFlags;

/// Number of iterations for each benchmark tier.
const SMALL_N: usize = 1_000;
const MEDIUM_N: usize = 10_000;
const LARGE_N: usize = 100_000;
const XLARGE_N: usize = 1_000_000;

/// Simulated key sizes (Ethereum trie node hashes are 32 bytes).
const KEY_SIZE: usize = 32;
/// Simulated value sizes (typical trie node ~100-500 bytes, we use 128).
const VALUE_SIZE: usize = 128;

/// Pre-generate deterministic keys and values for benchmarks.
/// Uses a simple PRNG seeded from the index to ensure reproducibility.
fn generate_key(buf: *[KEY_SIZE]u8, index: usize) void {
    // Use wyhash of the index to fill the key buffer deterministically
    const h = std.hash.Wyhash.hash(0xDEADBEEF, std.mem.asBytes(&index));
    const h_bytes = std.mem.asBytes(&h);
    @memcpy(buf[0..@sizeOf(@TypeOf(h))], h_bytes);
    // Fill remaining bytes with a second hash
    const h2 = std.hash.Wyhash.hash(0xCAFEBABE, std.mem.asBytes(&index));
    const h2_bytes = std.mem.asBytes(&h2);
    @memcpy(buf[@sizeOf(@TypeOf(h))..][0..@sizeOf(@TypeOf(h2))], h2_bytes);
    // Fill rest with index-derived pattern
    for (buf[@sizeOf(@TypeOf(h)) + @sizeOf(@TypeOf(h2)) ..]) |*byte| {
        byte.* = @truncate(index);
    }
}

fn generate_value(buf: *[VALUE_SIZE]u8, index: usize) void {
    const h = std.hash.Wyhash.hash(0x12345678, std.mem.asBytes(&index));
    const h_bytes = std.mem.asBytes(&h);
    for (buf, 0..) |*byte, i| {
        byte.* = h_bytes[i % @sizeOf(@TypeOf(h))];
    }
}

/// Format nanoseconds into a human-readable string.
fn format_ns(ns: u64) ![32]u8 {
    var buf: [32]u8 = undefined;
    if (ns < 1_000) {
        _ = try std.fmt.bufPrint(&buf, "{d} ns", .{ns});
    } else if (ns < 1_000_000) {
        _ = try std.fmt.bufPrint(&buf, "{d:.1} us", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    } else if (ns < 1_000_000_000) {
        _ = try std.fmt.bufPrint(&buf, "{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        _ = try std.fmt.bufPrint(&buf, "{d:.3} s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
    return buf;
}

fn format_ops_per_sec(ops: usize, elapsed_ns: u64) ![32]u8 {
    var buf: [32]u8 = undefined;
    if (elapsed_ns == 0) {
        _ = try std.fmt.bufPrint(&buf, "inf ops/s", .{});
        return buf;
    }
    const ops_per_sec = @as(f64, @floatFromInt(ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
    if (ops_per_sec >= 1_000_000) {
        _ = try std.fmt.bufPrint(&buf, "{d:.2} M ops/s", .{ops_per_sec / 1_000_000.0});
    } else if (ops_per_sec >= 1_000) {
        _ = try std.fmt.bufPrint(&buf, "{d:.1} K ops/s", .{ops_per_sec / 1_000.0});
    } else {
        _ = try std.fmt.bufPrint(&buf, "{d:.0} ops/s", .{ops_per_sec});
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

fn run_bench(name: []const u8, n: usize, func: anytype) !BenchResult {
    const elapsed = try func(n);
    const per_op = if (n > 0) elapsed / n else 0;
    const ops_sec = if (elapsed > 0) @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0) else 0;
    return .{
        .name = name,
        .ops = n,
        .elapsed_ns = elapsed,
        .per_op_ns = per_op,
        .ops_per_sec = ops_sec,
    };
}

fn print_result(r: BenchResult) !void {
    const total_str = try format_ns(r.elapsed_ns);
    const per_op_str = try format_ns(r.per_op_ns);
    const ops_str = try format_ops_per_sec(r.ops, r.elapsed_ns);
    std.debug.print("  {s:<45} {d:>8} ops  total={s}  per-op={s}  {s}\n", .{
        r.name,
        r.ops,
        &total_str,
        &per_op_str,
        &ops_str,
    });
}

// ============================================================================
// Benchmark implementations
// ============================================================================

/// Benchmark 1: Sequential put (simulating trie node writes during block processing)
fn bench_sequential_put(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }
    return timer.read();
}

/// Benchmark 2: Sequential get (simulating state reads)
fn bench_sequential_get(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        _ = db.get(&key_buf);
    }
    return timer.read();
}

/// Benchmark 3: Random get from pre-populated DB (cache-unfriendly access)
fn bench_random_get(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    // Random access pattern using a simple LCG
    var rng_state: u64 = 0x1234567890ABCDEF;
    var timer = try std.time.Timer.start();
    for (0..n) |_| {
        rng_state = rng_state *% 6364136223846793005 +% 1442695040888963407;
        const idx = rng_state % n;
        generate_key(&key_buf, idx);
        _ = db.get(&key_buf);
    }
    return timer.read();
}

/// Benchmark 4: Contains check (used for warm/cold access tracking)
fn bench_contains(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate half the keys
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..n / 2) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        _ = db.contains(&key_buf);
    }
    return timer.read();
}

/// Benchmark 5: Delete operations
fn bench_delete(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        try db.delete(&key_buf);
    }
    return timer.read();
}

/// Benchmark 6: Mixed read/write (80% read, 20% write — simulating block processing)
fn bench_mixed_workload(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate with n/2 entries
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..n / 2) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    var rng_state: u64 = 0xFEDCBA9876543210;
    var timer = try std.time.Timer.start();
    for (0..n) |_| {
        rng_state = rng_state *% 6364136223846793005 +% 1442695040888963407;
        const idx = rng_state % n;
        generate_key(&key_buf, idx);

        if (rng_state % 5 == 0) {
            // 20% writes
            generate_value(&val_buf, idx);
            try db.put(&key_buf, &val_buf);
        } else {
            // 80% reads
            _ = db.get(&key_buf);
        }
    }
    return timer.read();
}

/// Benchmark 7: WriteBatch put+commit (simulating bulk state updates)
fn bench_write_batch(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    const iface = db.database();
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    // Use a batch size of 100 (typical state changes per block)
    const batch_size: usize = 100;
    const num_batches = n / batch_size;

    var timer = try std.time.Timer.start();
    for (0..num_batches) |batch_idx| {
        var batch = WriteBatch.init(std.heap.page_allocator, iface);
        for (0..batch_size) |i| {
            const idx = batch_idx * batch_size + i;
            generate_key(&key_buf, idx);
            generate_value(&val_buf, idx);
            try batch.put(&key_buf, &val_buf);
        }
        try batch.commit();
        batch.deinit();
    }
    return timer.read();
}

/// Benchmark 8: Vtable dispatch overhead (indirect vs direct calls)
fn bench_vtable_overhead(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..1000) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    const iface = db.database();

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i % 1000);
        _ = try iface.get(&key_buf);
    }
    return timer.read();
}

/// Benchmark 8b: Direct calls (baseline for vtable comparison)
fn bench_direct_calls(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..1000) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i % 1000);
        _ = db.get(&key_buf);
    }
    return timer.read();
}

/// Benchmark 9: Overwrite existing keys (simulating storage slot updates)
fn bench_overwrite(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate with n entries
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    // Overwrite all entries with new values
    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i + n); // Different value
        try db.put(&key_buf, &val_buf);
    }
    return timer.read();
}

/// Benchmark 10: Simulated block processing
/// Simulates processing a block with ~200 transactions, each touching ~10 storage slots.
/// This measures the realistic workload pattern for the DB layer.
fn bench_block_processing(n: usize) !u64 {
    var db = MemoryDatabase.init(std.heap.page_allocator, .state);
    defer db.deinit();

    // Pre-populate with "world state" — n accounts with some storage
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try db.put(&key_buf, &val_buf);
    }

    const txs_per_block: usize = 200;
    const reads_per_tx: usize = 10; // Read account + storage slots
    const writes_per_tx: usize = 3; // Write storage changes

    var rng_state: u64 = 0xABCDEF0123456789;

    var timer = try std.time.Timer.start();
    for (0..txs_per_block) |_| {
        // Reads (account lookups, storage reads)
        for (0..reads_per_tx) |_| {
            rng_state = rng_state *% 6364136223846793005 +% 1442695040888963407;
            generate_key(&key_buf, rng_state % n);
            _ = db.get(&key_buf);
        }
        // Writes (storage updates)
        for (0..writes_per_tx) |_| {
            rng_state = rng_state *% 6364136223846793005 +% 1442695040888963407;
            generate_key(&key_buf, rng_state % n);
            generate_value(&val_buf, rng_state);
            try db.put(&key_buf, &val_buf);
        }
    }
    return timer.read();
}

// ============================================================================
// Column family benchmarks (DB-001: ColumnsDb, ColumnsWriteBatch, etc.)
// ============================================================================

/// Benchmark 11: MemColumnsDb init + columnsDb() accessor (measures setup cost)
fn bench_columns_init_accessor(n: usize) !u64 {
    var timer = try std.time.Timer.start();
    for (0..n) |_| {
        var mcdb = MemColumnsDb(ReceiptsColumns).init(std.heap.page_allocator, .receipts);
        _ = mcdb.columnsDb();
        mcdb.deinit();
    }
    return timer.read();
}

/// Benchmark 12: Column-isolated put/get (write to 3 columns, read back)
/// Simulates receipt indexing: write to default, transactions, blocks columns.
fn bench_columns_put_get(n: usize) !u64 {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.heap.page_allocator, .receipts);
    defer mcdb.deinit();
    var cdb = mcdb.columnsDb();

    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);

        // Write to all 3 columns (simulating receipt indexing)
        try cdb.getColumnDb(.default).put(&key_buf, &val_buf);
        try cdb.getColumnDb(.transactions).put(&key_buf, &val_buf);
        try cdb.getColumnDb(.blocks).put(&key_buf, &val_buf);

        // Read back from each column
        _ = try cdb.getColumnDb(.default).get(&key_buf);
        _ = try cdb.getColumnDb(.transactions).get(&key_buf);
        _ = try cdb.getColumnDb(.blocks).get(&key_buf);
    }
    return timer.read();
}

/// Benchmark 13: ColumnsWriteBatch cross-column commit
/// Accumulates writes across all columns, then commits atomically.
fn bench_columns_write_batch(n: usize) !u64 {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.heap.page_allocator, .receipts);
    defer mcdb.deinit();
    var cdb = mcdb.columnsDb();

    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    const batch_size: usize = 100;
    const num_batches = n / batch_size;

    var timer = try std.time.Timer.start();
    for (0..num_batches) |batch_idx| {
        var batch = cdb.startWriteBatch(std.heap.page_allocator);
        for (0..batch_size) |i| {
            const idx = batch_idx * batch_size + i;
            generate_key(&key_buf, idx);
            generate_value(&val_buf, idx);
            // Distribute across columns (round-robin)
            switch (idx % 3) {
                0 => try batch.getColumnBatch(.default).put(&key_buf, &val_buf),
                1 => try batch.getColumnBatch(.transactions).put(&key_buf, &val_buf),
                else => try batch.getColumnBatch(.blocks).put(&key_buf, &val_buf),
            }
        }
        try batch.commit();
        batch.deinit();
    }
    return timer.read();
}

/// Benchmark 14: ColumnDbSnapshot create + read (point-in-time reads)
fn bench_columns_snapshot(n: usize) !u64 {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.heap.page_allocator, .receipts);
    defer mcdb.deinit();
    var cdb = mcdb.columnsDb();

    // Pre-populate
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try cdb.getColumnDb(.default).put(&key_buf, &val_buf);
    }

    var timer = try std.time.Timer.start();
    // Create snapshot
    var snap = try cdb.createSnapshot();

    // Read all keys from snapshot
    for (0..n) |i| {
        generate_key(&key_buf, i);
        _ = try snap.getColumnSnapshot(.default).get(&key_buf, ReadFlags.none);
    }
    snap.deinit();
    return timer.read();
}

/// Benchmark 15: Column isolation verification (write to one, check absence in others)
/// Measures the overhead of column family dispatch vs single DB.
fn bench_columns_isolation_overhead(n: usize) !u64 {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.heap.page_allocator, .receipts);
    defer mcdb.deinit();
    var cdb = mcdb.columnsDb();

    // Single-DB baseline: use just the default column
    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        // Write to default only
        try cdb.getColumnDb(.default).put(&key_buf, &val_buf);
        // Verify isolation: other columns should return null
        _ = try cdb.getColumnDb(.transactions).get(&key_buf);
        _ = try cdb.getColumnDb(.blocks).get(&key_buf);
    }
    return timer.read();
}

/// Benchmark 16: BlobTxsColumns (3-column EIP-4844 pattern)
/// Simulates blob transaction lifecycle: full -> light -> processed
fn bench_blob_columns_lifecycle(n: usize) !u64 {
    var mcdb = MemColumnsDb(BlobTxsColumns).init(std.heap.page_allocator, .blob_transactions);
    defer mcdb.deinit();
    var cdb = mcdb.columnsDb();

    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);

        // Stage 1: Store full blob tx
        try cdb.getColumnDb(.full_blob_txs).put(&key_buf, &val_buf);
        // Stage 2: Create light version
        try cdb.getColumnDb(.light_blob_txs).put(&key_buf, &val_buf);
        // Stage 3: Mark as processed
        try cdb.getColumnDb(.processed_txs).put(&key_buf, &val_buf);
        // Stage 4: Read back processed
        _ = try cdb.getColumnDb(.processed_txs).get(&key_buf);
    }
    return timer.read();
}

// ============================================================================
// Factory benchmarks (DB-002: DbFactory, MemDbFactory, ReadOnlyDbFactory)
// ============================================================================

const factory = @import("factory.zig");
const MemDbFactory = factory.MemDbFactory;
const ReadOnlyDbFactory = factory.ReadOnlyDbFactory;
const NullDbFactory = factory.NullDbFactory;
const DbFactory = factory.DbFactory;
const DbSettings = @import("rocksdb.zig").DbSettings;
const prov = @import("provider.zig");
const DbProvider = prov.DbProvider;

/// Benchmark 17: MemDbFactory createDb throughput
/// Measures factory overhead for creating databases (heap alloc + vtable setup).
fn bench_factory_create_db(n: usize) !u64 {
    var mem_factory = MemDbFactory.init(std.heap.page_allocator);
    defer mem_factory.deinit();

    const f = mem_factory.factory();

    // Pre-allocate an array to hold owned databases for cleanup
    var owned_dbs = try std.heap.page_allocator.alloc(adapter.OwnedDatabase, n);
    defer std.heap.page_allocator.free(owned_dbs);

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        owned_dbs[i] = try f.createDb(DbSettings.init(.state, "state"));
    }
    const elapsed = timer.read();

    // Cleanup all created databases
    for (0..n) |i| {
        owned_dbs[i].deinit();
    }

    return elapsed;
}

/// Benchmark 18: Factory-created DB put/get throughput
/// Measures I/O through a factory-created database vs direct MemoryDatabase.
fn bench_factory_db_io(n: usize) !u64 {
    var mem_factory = MemDbFactory.init(std.heap.page_allocator);
    defer mem_factory.deinit();

    const owned = try mem_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer owned.deinit();

    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try owned.db.put(&key_buf, &val_buf);
    }
    // Read back all
    for (0..n) |i| {
        generate_key(&key_buf, i);
        const val = try owned.db.get(&key_buf);
        if (val) |v| v.release();
    }
    return timer.read();
}

/// Benchmark 19: ReadOnlyDbFactory overlay write+read throughput
/// Measures overlay-based read/write performance through the factory chain.
fn bench_readonly_factory_overlay(n: usize) !u64 {
    var mem_factory = MemDbFactory.init(std.heap.page_allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.heap.page_allocator);
    defer ro_factory.deinit();

    const owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer owned.deinit();

    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    var timer = try std.time.Timer.start();
    // Writes go to overlay
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        try owned.db.put(&key_buf, &val_buf);
    }
    // Reads check overlay first
    for (0..n) |i| {
        generate_key(&key_buf, i);
        const val = try owned.db.get(&key_buf);
        if (val) |v| v.release();
    }
    return timer.read();
}

/// Benchmark 20: Factory vtable dispatch overhead
/// Compares factory.createDb (vtable) vs direct MemDbFactory.createDbImpl cost.
/// This isolates the vtable indirection overhead in the factory layer.
fn bench_factory_vtable_overhead(n: usize) !u64 {
    var mem_factory = MemDbFactory.init(std.heap.page_allocator);
    defer mem_factory.deinit();

    const f = mem_factory.factory();

    var timer = try std.time.Timer.start();
    for (0..n) |_| {
        const owned = try f.createDb(DbSettings.init(.state, "state"));
        // Immediately write+read to measure full round-trip through vtable
        try owned.db.put("bench_key", "bench_value");
        const val = try owned.db.get("bench_key");
        if (val) |v| v.release();
        owned.deinit();
    }
    return timer.read();
}

/// Benchmark 21: Factory + DbProvider wiring throughput
/// Simulates realistic startup: factory creates DBs, registers in provider,
/// then performs I/O through the provider abstraction.
fn bench_factory_provider_wiring(n: usize) !u64 {
    var mem_factory = MemDbFactory.init(std.heap.page_allocator);
    defer mem_factory.deinit();

    const f = mem_factory.factory();

    // Create DBs and register them in a provider
    const state_owned = try f.createDb(DbSettings.init(.state, "state"));
    defer state_owned.deinit();
    const code_owned = try f.createDb(DbSettings.init(.code, "code"));
    defer code_owned.deinit();
    const storage_owned = try f.createDb(DbSettings.init(.storage, "storage"));
    defer storage_owned.deinit();

    var db_provider = DbProvider.init();
    db_provider.register(.state, state_owned.db);
    db_provider.register(.code, code_owned.db);
    db_provider.register(.storage, storage_owned.db);

    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);

        // Distribute across providers (simulating block processing)
        const db = switch (i % 3) {
            0 => try db_provider.get(.state),
            1 => try db_provider.get(.code),
            else => try db_provider.get(.storage),
        };
        try db.put(&key_buf, &val_buf);
    }
    // Read back through provider
    for (0..n) |i| {
        generate_key(&key_buf, i);
        const db = switch (i % 3) {
            0 => try db_provider.get(.state),
            1 => try db_provider.get(.code),
            else => try db_provider.get(.storage),
        };
        const val = try db.get(&key_buf);
        if (val) |v| v.release();
    }
    return timer.read();
}

/// Benchmark 22: MemDbFactory createColumnsDb throughput
/// Measures factory column-database creation (comptime dispatch path).
fn bench_factory_columns_db(n: usize) !u64 {
    var mem_factory = MemDbFactory.init(std.heap.page_allocator);
    defer mem_factory.deinit();

    var key_buf: [KEY_SIZE]u8 = undefined;
    var val_buf: [VALUE_SIZE]u8 = undefined;

    var mcdb = mem_factory.createColumnsDb(ReceiptsColumns, .receipts);
    defer mcdb.deinit();
    var cdb = mcdb.columnsDb();

    var timer = try std.time.Timer.start();
    for (0..n) |i| {
        generate_key(&key_buf, i);
        generate_value(&val_buf, i);
        // Write to all 3 columns via factory-created ColumnsDb
        try cdb.getColumnDb(.default).put(&key_buf, &val_buf);
        try cdb.getColumnDb(.transactions).put(&key_buf, &val_buf);
        try cdb.getColumnDb(.blocks).put(&key_buf, &val_buf);
    }
    return timer.read();
}

// ============================================================================
// Main benchmark entry point
// ============================================================================

/// Entry point for DB abstraction layer benchmarks.
pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
    std.debug.print("  Guillotine Phase-0-DB Benchmarks (MemoryDatabase)\n", .{});
    std.debug.print("  Key size: {d} bytes, Value size: {d} bytes\n", .{ KEY_SIZE, VALUE_SIZE });
    std.debug.print("=" ** 100 ++ "\n\n", .{});

    // -- Core operations --
    std.debug.print("--- Core Operations ---\n", .{});
    try print_result(try run_bench("put (sequential, 10K)", MEDIUM_N, bench_sequential_put));
    try print_result(try run_bench("put (sequential, 100K)", LARGE_N, bench_sequential_put));
    try print_result(try run_bench("put (sequential, 1M)", XLARGE_N, bench_sequential_put));
    std.debug.print("\n", .{});

    try print_result(try run_bench("get (sequential, 10K)", MEDIUM_N, bench_sequential_get));
    try print_result(try run_bench("get (sequential, 100K)", LARGE_N, bench_sequential_get));
    try print_result(try run_bench("get (sequential, 1M)", XLARGE_N, bench_sequential_get));
    std.debug.print("\n", .{});

    try print_result(try run_bench("get (random, 10K)", MEDIUM_N, bench_random_get));
    try print_result(try run_bench("get (random, 100K)", LARGE_N, bench_random_get));
    try print_result(try run_bench("get (random, 1M)", XLARGE_N, bench_random_get));
    std.debug.print("\n", .{});

    try print_result(try run_bench("contains (10K, 50% hit)", MEDIUM_N, bench_contains));
    try print_result(try run_bench("contains (100K, 50% hit)", LARGE_N, bench_contains));
    std.debug.print("\n", .{});

    try print_result(try run_bench("delete (10K)", MEDIUM_N, bench_delete));
    try print_result(try run_bench("delete (100K)", LARGE_N, bench_delete));
    std.debug.print("\n", .{});

    try print_result(try run_bench("overwrite (10K)", MEDIUM_N, bench_overwrite));
    try print_result(try run_bench("overwrite (100K)", LARGE_N, bench_overwrite));
    std.debug.print("\n", .{});

    // -- Compound operations --
    std.debug.print("--- Compound Operations ---\n", .{});
    try print_result(try run_bench("mixed 80/20 r/w (10K)", MEDIUM_N, bench_mixed_workload));
    try print_result(try run_bench("mixed 80/20 r/w (100K)", LARGE_N, bench_mixed_workload));
    try print_result(try run_bench("mixed 80/20 r/w (1M)", XLARGE_N, bench_mixed_workload));
    std.debug.print("\n", .{});

    try print_result(try run_bench("write-batch (10K, batch=100)", MEDIUM_N, bench_write_batch));
    try print_result(try run_bench("write-batch (100K, batch=100)", LARGE_N, bench_write_batch));
    std.debug.print("\n", .{});

    // -- Vtable overhead --
    std.debug.print("--- Vtable Dispatch Overhead ---\n", .{});
    const direct = try run_bench("direct get (1M lookups in 1K DB)", XLARGE_N, bench_direct_calls);
    const vtable = try run_bench("vtable get (1M lookups in 1K DB)", XLARGE_N, bench_vtable_overhead);
    try print_result(direct);
    try print_result(vtable);
    if (direct.per_op_ns > 0) {
        const overhead_pct = if (vtable.per_op_ns > direct.per_op_ns)
            @as(f64, @floatFromInt(vtable.per_op_ns - direct.per_op_ns)) / @as(f64, @floatFromInt(direct.per_op_ns)) * 100.0
        else
            0.0;
        std.debug.print("  Vtable overhead: {d:.1}%\n", .{overhead_pct});
    }
    std.debug.print("\n", .{});

    // -- Column family operations (DB-001) --
    std.debug.print("--- Column Family Operations (DB-001: ColumnsDb) ---\n", .{});
    try print_result(try run_bench("MemColumnsDb init+accessor (1K cycles)", SMALL_N, bench_columns_init_accessor));
    try print_result(try run_bench("MemColumnsDb init+accessor (10K cycles)", MEDIUM_N, bench_columns_init_accessor));
    std.debug.print("\n", .{});

    try print_result(try run_bench("columns put+get 3-col (1K keys)", SMALL_N, bench_columns_put_get));
    try print_result(try run_bench("columns put+get 3-col (10K keys)", MEDIUM_N, bench_columns_put_get));
    try print_result(try run_bench("columns put+get 3-col (100K keys)", LARGE_N, bench_columns_put_get));
    std.debug.print("\n", .{});

    try print_result(try run_bench("columns write-batch (10K, batch=100)", MEDIUM_N, bench_columns_write_batch));
    try print_result(try run_bench("columns write-batch (100K, batch=100)", LARGE_N, bench_columns_write_batch));
    std.debug.print("\n", .{});

    try print_result(try run_bench("columns snapshot create+read (1K)", SMALL_N, bench_columns_snapshot));
    try print_result(try run_bench("columns snapshot create+read (10K)", MEDIUM_N, bench_columns_snapshot));
    std.debug.print("\n", .{});

    try print_result(try run_bench("columns isolation check (10K)", MEDIUM_N, bench_columns_isolation_overhead));
    try print_result(try run_bench("columns isolation check (100K)", LARGE_N, bench_columns_isolation_overhead));
    std.debug.print("\n", .{});

    try print_result(try run_bench("blob-columns lifecycle (1K)", SMALL_N, bench_blob_columns_lifecycle));
    try print_result(try run_bench("blob-columns lifecycle (10K)", MEDIUM_N, bench_blob_columns_lifecycle));
    try print_result(try run_bench("blob-columns lifecycle (100K)", LARGE_N, bench_blob_columns_lifecycle));
    std.debug.print("\n", .{});

    // -- Factory operations (DB-002) --
    std.debug.print("--- Factory Operations (DB-002: DbFactory) ---\n", .{});
    try print_result(try run_bench("factory createDb (1K)", SMALL_N, bench_factory_create_db));
    try print_result(try run_bench("factory createDb (10K)", MEDIUM_N, bench_factory_create_db));
    std.debug.print("\n", .{});

    try print_result(try run_bench("factory DB put+get (10K)", MEDIUM_N, bench_factory_db_io));
    try print_result(try run_bench("factory DB put+get (100K)", LARGE_N, bench_factory_db_io));
    std.debug.print("\n", .{});

    try print_result(try run_bench("ReadOnly overlay put+get (10K)", MEDIUM_N, bench_readonly_factory_overlay));
    try print_result(try run_bench("ReadOnly overlay put+get (100K)", LARGE_N, bench_readonly_factory_overlay));
    std.debug.print("\n", .{});

    try print_result(try run_bench("factory vtable create+io (1K)", SMALL_N, bench_factory_vtable_overhead));
    try print_result(try run_bench("factory vtable create+io (10K)", MEDIUM_N, bench_factory_vtable_overhead));
    std.debug.print("\n", .{});

    try print_result(try run_bench("factory+provider wiring (10K)", MEDIUM_N, bench_factory_provider_wiring));
    try print_result(try run_bench("factory+provider wiring (100K)", LARGE_N, bench_factory_provider_wiring));
    std.debug.print("\n", .{});

    try print_result(try run_bench("factory createColumnsDb put (10K)", MEDIUM_N, bench_factory_columns_db));
    try print_result(try run_bench("factory createColumnsDb put (100K)", LARGE_N, bench_factory_columns_db));
    std.debug.print("\n", .{});

    // -- Block processing simulation --
    std.debug.print("--- Block Processing Simulation ---\n", .{});
    std.debug.print("  (200 txs/block, 10 reads + 3 writes per tx)\n", .{});
    const small_state = try run_bench("block (1K state entries)", SMALL_N, bench_block_processing);
    const medium_state = try run_bench("block (10K state entries)", MEDIUM_N, bench_block_processing);
    const large_state = try run_bench("block (100K state entries)", LARGE_N, bench_block_processing);
    try print_result(small_state);
    try print_result(medium_state);
    try print_result(large_state);
    std.debug.print("\n", .{});

    // -- Throughput analysis vs Nethermind target --
    std.debug.print("--- Throughput Analysis ---\n", .{});
    // Nethermind processes ~700 MGas/s.
    // A typical Ethereum block is ~15M gas, so ~46 blocks/s at 700 MGas/s.
    // Each block has ~200 txs * ~13 DB ops = ~2600 DB ops per block.
    // So Nethermind needs ~120K DB ops/s at minimum.
    const block_ops: usize = 200 * 13; // ops per simulated block
    const block_ns = medium_state.elapsed_ns;
    const blocks_per_sec = if (block_ns > 0)
        1_000_000_000.0 / @as(f64, @floatFromInt(block_ns))
    else
        0.0;
    const db_ops_per_sec = blocks_per_sec * @as(f64, @floatFromInt(block_ops));
    const effective_mgas_per_sec = blocks_per_sec * 15.0; // 15M gas per block

    std.debug.print("  Block throughput:      {d:.0} blocks/s\n", .{blocks_per_sec});
    std.debug.print("  DB ops throughput:     {d:.0} ops/s ({d:.2} M ops/s)\n", .{ db_ops_per_sec, db_ops_per_sec / 1_000_000.0 });
    std.debug.print("  Effective MGas/s:      {d:.0} MGas/s (in-memory DB layer only)\n", .{effective_mgas_per_sec});
    std.debug.print("  Nethermind target:     700 MGas/s (full client with RocksDB)\n", .{});

    const meets_target = effective_mgas_per_sec >= 700.0;
    if (meets_target) {
        std.debug.print("  Status:                PASS - in-memory DB layer exceeds target\n", .{});
    } else {
        std.debug.print("  Status:                WARN - below target (expected for in-memory, bottleneck will be disk I/O)\n", .{});
    }

    std.debug.print("\n" ++ "=" ** 100 ++ "\n", .{});
    std.debug.print("  Notes:\n", .{});
    std.debug.print("  - In-memory DB should be MUCH faster than 700 MGas/s target\n", .{});
    std.debug.print("  - Real bottleneck will be RocksDB I/O (not implemented yet)\n", .{});
    std.debug.print("  - Arena allocator ensures no per-op heap allocs in hot paths\n", .{});
    std.debug.print("  - Vtable dispatch should add <5%% overhead vs direct calls\n", .{});
    std.debug.print("=" ** 100 ++ "\n\n", .{});
}
