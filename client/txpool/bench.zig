/// Benchmarks for the Transaction Pool (phase-5-txpool).
///
/// Focus areas:
/// - Admission sizing: `fits_size_limits` across mixed tx types
/// - Fee sorting hot path: `compare_fee_market_priority` (standalone + sort)
///
/// Notes:
/// - Voltaire primitives do not expose EIP-2930 transactions in this build; the
///   admission bench covers Legacy, EIP-1559, EIP-4844, and EIP-7702 only.
///
/// Run:
///   zig build bench-txpool                         # Debug timings (sanity)
///   zig build bench-txpool -Doptimize=ReleaseFast  # Release timings (use these)
const std = @import("std");
const builtin = @import("builtin");
const bench = @import("bench_utils");
const primitives = @import("primitives");
const txpool = @import("root.zig");

const Address = primitives.Address;
const Tx = primitives.Transaction;
const TransactionHash = primitives.TransactionHash.TransactionHash;
const TransactionType = primitives.Transaction.TransactionType;
const GasPrice = primitives.GasPrice;
const MaxFeePerGas = primitives.MaxFeePerGas;
const MaxPriorityFeePerGas = primitives.MaxPriorityFeePerGas;
const BaseFeePerGas = primitives.BaseFeePerGas;
const VersionedHash = primitives.Blob.VersionedHash;
const TxPool = txpool.TxPool;

// Workloads
const N_ADMISSION_SMALL: usize = 5_000; // Per-type sample size
const N_ADMISSION_MED: usize = 20_000; // Per-type sample size
const N_SORT: usize = 50_000; // Fee tuples for sort bench
const N_LOOKUP: usize = 50_000_000; // Interface lookups for is_known/contains_tx

const BenchWorkload = struct {
    admission_small: usize,
    admission_medium: usize,
    sort: usize,
    lookup: usize,
};

fn benchmark_workload() BenchWorkload {
    if (builtin.is_test) {
        return .{
            .admission_small = 16,
            .admission_medium = 32,
            .sort = 128,
            .lookup = 1_024,
        };
    }
    return .{
        .admission_small = N_ADMISSION_SMALL,
        .admission_medium = N_ADMISSION_MED,
        .sort = N_SORT,
        .lookup = N_LOOKUP,
    };
}

fn mk_addr(byte: u8) Address {
    return .{ .bytes = [_]u8{byte} ++ [_]u8{0} ** 19 };
}

fn mk_vhash(byte: u8) VersionedHash {
    return .{ .bytes = [_]u8{byte} ++ [_]u8{0} ** 31 };
}

noinline fn fits_size_limits_ok(tx: anytype, cfg: txpool.TxPoolConfig) !void {
    try txpool.fits_size_limits(tx, cfg);
}

fn bench_admission(n_per_type: usize) !bench.BenchResult {
    // Config with generous size caps (should all pass)
    var cfg = txpool.TxPoolConfig{};
    cfg.max_tx_size = 256 * 1024; // legacy/1559/2930/7702
    cfg.max_blob_tx_size = 1024 * 1024; // 4844 (excludes blobs)

    // Prepare a small mix of transactions
    var ops: usize = 0;
    var accepted_count: usize = 0;
    var timer = try std.time.Timer.start();

    // Legacy
    {
        const tx = Tx.LegacyTransaction{
            .nonce = 0,
            .gas_price = 1,
            .gas_limit = 21_000,
            .to = mk_addr(0x11),
            .value = 0,
            .data = &[_]u8{},
            .v = 37,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        };
        for (0..n_per_type) |_| {
            try fits_size_limits_ok(tx, cfg);
            accepted_count +%= 1;
        }
        ops += n_per_type;
    }

    // EIP-1559
    {
        const tx = Tx.Eip1559Transaction{
            .chain_id = 1,
            .nonce = 0,
            .max_priority_fee_per_gas = 1,
            .max_fee_per_gas = 2,
            .gas_limit = 21_000,
            .to = mk_addr(0x22),
            .value = 0,
            .data = &[_]u8{},
            .access_list = &[_]Tx.AccessListItem{},
            .y_parity = 1,
            .r = [_]u8{1} ** 32,
            .s = [_]u8{2} ** 32,
        };
        for (0..n_per_type) |_| {
            try fits_size_limits_ok(tx, cfg);
            accepted_count +%= 1;
        }
        ops += n_per_type;
    }

    // EIP-2930 is intentionally omitted (not present in primitives here).

    // EIP-4844 (blob tx; size excludes blobs)
    {
        const hashes = [_]VersionedHash{mk_vhash(0xAA)};
        const tx = Tx.Eip4844Transaction{
            .chain_id = 1,
            .nonce = 0,
            .max_priority_fee_per_gas = 1,
            .max_fee_per_gas = 2,
            .gas_limit = 21_000,
            .to = mk_addr(0x33), // non-null
            .value = 0,
            .data = &[_]u8{},
            .access_list = &[_]Tx.AccessListItem{},
            .max_fee_per_blob_gas = 1,
            .blob_versioned_hashes = &hashes,
            .y_parity = 1,
            .r = [_]u8{3} ** 32,
            .s = [_]u8{4} ** 32,
        };
        for (0..n_per_type) |_| {
            try fits_size_limits_ok(tx, cfg);
            accepted_count +%= 1;
        }
        ops += n_per_type;
    }

    // EIP-7702 (authorization list; empty here)
    {
        const Authorization = primitives.Authorization.Authorization;
        const tx = Tx.Eip7702Transaction{
            .chain_id = 1,
            .nonce = 0,
            .max_priority_fee_per_gas = 1,
            .max_fee_per_gas = 2,
            .gas_limit = 21_000,
            .to = mk_addr(0x44),
            .value = 0,
            .data = &[_]u8{},
            .access_list = &[_]Tx.AccessListItem{},
            .authorization_list = &[_]Authorization{},
            .y_parity = 0,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        };
        for (0..n_per_type) |_| {
            try fits_size_limits_ok(tx, cfg);
            accepted_count +%= 1;
        }
        ops += n_per_type;
    }

    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(accepted_count);
    const per_op = if (ops > 0) elapsed / ops else 0;
    return .{
        .name = "txpool.admission: fits_size_limits (mixed types)",
        .ops = ops,
        .elapsed_ns = elapsed,
        .per_op_ns = per_op,
        .ops_per_sec = if (elapsed > 0) @as(f64, @floatFromInt(ops)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) else 0,
    };
}

const FeeTuple = struct {
    gas_price: GasPrice,
    max_fee: MaxFeePerGas,
    max_priority: MaxPriorityFeePerGas,
};

fn bench_fee_compare_only(n: usize) !bench.BenchResult {
    // Deterministic input set
    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = rng.random();

    var tuples = std.ArrayList(FeeTuple).empty;
    try tuples.ensureTotalCapacityPrecise(std.heap.page_allocator, n);
    defer tuples.deinit(std.heap.page_allocator);

    for (0..n) |_| {
        // Randomize: mix legacy-like and 1559-like
        const gp = GasPrice.from(@as(u64, random.intRangeAtMost(u64, 0, 100_000_000_000)));
        const mf = MaxFeePerGas.from(@as(u64, random.intRangeAtMost(u64, 0, 200_000_000_000)));
        const mp = MaxPriorityFeePerGas.from(@as(u64, random.intRangeAtMost(u64, 0, 10_000_000_000)));
        tuples.appendAssumeCapacity(.{ .gas_price = gp, .max_fee = mf, .max_priority = mp });
    }

    const base_fee = BaseFeePerGas.from(15_000_000_000);
    var timer = try std.time.Timer.start();
    var cmp_count: usize = 0;
    var cmp_acc: i64 = 0;
    // Just slam comparator without sorting cost
    for (tuples.items, 0..) |x, i| {
        const j = (i * 17 + 13) % tuples.items.len;
        const y = tuples.items[j];
        const cmp = txpool.compare_fee_market_priority(
            x.gas_price,
            x.max_fee,
            x.max_priority,
            y.gas_price,
            y.max_fee,
            y.max_priority,
            base_fee,
            true,
        );
        cmp_acc +%= cmp;
        cmp_count += 1;
    }
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(cmp_acc);
    const per = if (cmp_count > 0) elapsed / cmp_count else 0;
    return .{
        .name = "txpool.sort: fee comparator only (EIP-1559)",
        .ops = cmp_count,
        .elapsed_ns = elapsed,
        .per_op_ns = per,
        .ops_per_sec = if (elapsed > 0) @as(f64, @floatFromInt(cmp_count)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) else 0,
    };
}

fn bench_fee_sort(n: usize) !bench.BenchResult {
    var rng = std.Random.DefaultPrng.init(0xBADC0DE);
    const random = rng.random();

    var tuples = std.ArrayList(FeeTuple).empty;
    try tuples.ensureTotalCapacityPrecise(std.heap.page_allocator, n);
    defer tuples.deinit(std.heap.page_allocator);

    for (0..n) |_| {
        // Random mix of legacy-emulation and 1559
        const is_legacy = (random.int(u32) & 3) == 0; // ~25% legacy-like
        const gp = GasPrice.from(@as(u64, random.intRangeAtMost(u64, 1, 100_000_000_000)));
        const mf = if (is_legacy) MaxFeePerGas.from(0) else MaxFeePerGas.from(@as(u64, random.intRangeAtMost(u64, 1, 200_000_000_000)));
        const mp = if (is_legacy) MaxPriorityFeePerGas.from(0) else MaxPriorityFeePerGas.from(@as(u64, random.intRangeAtMost(u64, 1, 10_000_000_000)));
        tuples.appendAssumeCapacity(.{ .gas_price = gp, .max_fee = mf, .max_priority = mp });
    }

    const base_fee = BaseFeePerGas.from(25_000_000_000);
    var timer = try std.time.Timer.start();
    std.sort.block(FeeTuple, tuples.items, base_fee, struct {
        fn lessThan(base: BaseFeePerGas, a: FeeTuple, b: FeeTuple) bool {
            const r = txpool.compare_fee_market_priority(
                a.gas_price,
                a.max_fee,
                a.max_priority,
                b.gas_price,
                b.max_fee,
                b.max_priority,
                base,
                true,
            );
            // We want descending priority, so lessThan is inverted
            return r == 1; // a has lower priority than b → a < b
        }
    }.lessThan);
    const elapsed = timer.read();
    var checksum: u64 = 0;
    if (tuples.items.len > 0) {
        checksum ^= std.hash.Wyhash.hash(0, std.mem.asBytes(&tuples.items[0]));
        checksum ^= std.hash.Wyhash.hash(1, std.mem.asBytes(&tuples.items[tuples.items.len - 1]));
    }
    std.mem.doNotOptimizeAway(checksum);

    // Approximate comparator calls upper bound ~ n log2 n * C; we just report time/op by n
    const per = if (n > 0) elapsed / n else 0;
    return .{
        .name = "txpool.sort: sort N fee tuples (EIP-1559/legacy mix)",
        .ops = n,
        .elapsed_ns = elapsed,
        .per_op_ns = per,
        .ops_per_sec = if (elapsed > 0) @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) else 0,
    };
}

const LookupDummyPool = struct {
    known_hash: TransactionHash,
    known_type: TransactionType,

    fn pending_count(_: *anyopaque) u32 {
        return 0;
    }

    fn pending_blob_count(_: *anyopaque) u32 {
        return 0;
    }

    fn get_pending_transactions(_: *anyopaque) []const TxPool.PendingTransaction {
        return &[_]TxPool.PendingTransaction{};
    }

    fn supports_blobs(_: *anyopaque) bool {
        return true;
    }

    fn get_pending_count_for_sender(_: *anyopaque, _: Address) u32 {
        return 0;
    }

    fn get_pending_transactions_by_sender(_: *anyopaque, _: Address) []const TxPool.PendingTransaction {
        return &[_]TxPool.PendingTransaction{};
    }

    fn is_known(ptr: *anyopaque, tx_hash: TransactionHash) bool {
        const self: *LookupDummyPool = @ptrCast(@alignCast(ptr));
        return std.mem.eql(u8, &self.known_hash, &tx_hash);
    }

    fn mark_known_for_current_scope(_: *anyopaque, _: TransactionHash) void {}

    fn contains_tx(ptr: *anyopaque, tx_hash: TransactionHash, tx_type: TransactionType) bool {
        const self: *LookupDummyPool = @ptrCast(@alignCast(ptr));
        return std.mem.eql(u8, &self.known_hash, &tx_hash) and self.known_type == tx_type;
    }

    fn submit_tx(_: *anyopaque, _: *const TxPool.PendingTransaction, _: txpool.TxHandlingOptions) txpool.AcceptTxResult {
        return txpool.AcceptTxResult.accepted;
    }
};

fn bench_lookup_dispatch(n: usize) !struct { is_known: bench.BenchResult, contains_tx: bench.BenchResult } {
    var dummy = LookupDummyPool{
        .known_hash = [_]u8{0x11} ** 32,
        .known_type = .eip1559,
    };
    const vtable = TxPool.VTable{
        .pending_count = LookupDummyPool.pending_count,
        .pending_blob_count = LookupDummyPool.pending_blob_count,
        .get_pending_transactions = LookupDummyPool.get_pending_transactions,
        .supports_blobs = LookupDummyPool.supports_blobs,
        .get_pending_count_for_sender = LookupDummyPool.get_pending_count_for_sender,
        .get_pending_transactions_by_sender = LookupDummyPool.get_pending_transactions_by_sender,
        .is_known = LookupDummyPool.is_known,
        .mark_known_for_current_scope = LookupDummyPool.mark_known_for_current_scope,
        .contains_tx = LookupDummyPool.contains_tx,
        .submit_tx = LookupDummyPool.submit_tx,
    };
    const pool = TxPool{ .ptr = &dummy, .vtable = &vtable };

    const known_hash: TransactionHash = [_]u8{0x11} ** 32;
    const unknown_hash: TransactionHash = [_]u8{0x22} ** 32;

    var known_hits: usize = 0;
    var contains_hits: usize = 0;

    var timer_known = try std.time.Timer.start();
    for (0..n) |i| {
        const hash = if ((i & 1) == 0) known_hash else unknown_hash;
        if (pool.is_known(hash)) {
            known_hits +%= 1;
        }
    }
    const known_elapsed = timer_known.read();
    std.mem.doNotOptimizeAway(known_hits);

    var timer_contains = try std.time.Timer.start();
    for (0..n) |i| {
        const hash = if ((i & 1) == 0) known_hash else unknown_hash;
        const tx_type: TransactionType = if ((i & 3) == 0) .eip1559 else .legacy;
        if (pool.contains_tx(hash, tx_type)) {
            contains_hits +%= 1;
        }
    }
    const contains_elapsed = timer_contains.read();
    std.mem.doNotOptimizeAway(contains_hits);

    const known_per = if (n > 0) known_elapsed / n else 0;
    const contains_per = if (n > 0) contains_elapsed / n else 0;

    return .{
        .is_known = .{
            .name = "txpool.lookup: TxPool.is_known vtable dispatch",
            .ops = n,
            .elapsed_ns = known_elapsed,
            .per_op_ns = known_per,
            .ops_per_sec = if (known_elapsed > 0) @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(known_elapsed)) / 1e9) else 0,
        },
        .contains_tx = .{
            .name = "txpool.lookup: TxPool.contains_tx vtable dispatch",
            .ops = n,
            .elapsed_ns = contains_elapsed,
            .per_op_ns = contains_per,
            .ops_per_sec = if (contains_elapsed > 0) @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(contains_elapsed)) / 1e9) else 0,
        },
    };
}

/// Benchmark executable entrypoint for txpool admission/sorting hot paths.
pub fn main() !void {
    const workload = benchmark_workload();

    std.debug.print("\n" ++ "=" ** 100 ++ "\n", .{});
    std.debug.print("  Guillotine Phase-5-TxPool Benchmarks\n", .{});
    std.debug.print("  Warmup: implicit in generation; timings averaged per run\n", .{});
    std.debug.print("=" ** 100 ++ "\n\n", .{});

    // Admission (fits_size_limits) hot path.
    std.debug.print("--- Admission: fits_size_limits ---\n", .{});
    {
        const r_small = try bench_admission(workload.admission_small);
        bench.print_result(r_small);

        const r_med = try bench_admission(workload.admission_medium);
        bench.print_result(r_med);
    }
    std.debug.print("\n", .{});

    // Comparator-only and full sort
    std.debug.print("--- Fee Market Priority Sorting ---\n", .{});
    {
        const r_cmp = try bench_fee_compare_only(workload.sort);
        bench.print_result(r_cmp);

        const r_sort = try bench_fee_sort(workload.sort);
        bench.print_result(r_sort);
    }
    std.debug.print("\n", .{});

    // TxPool vtable lookup dispatch hot path
    std.debug.print("--- TxPool Lookup Dispatch ---\n", .{});
    {
        const r_lookup = try bench_lookup_dispatch(workload.lookup);
        bench.print_result(r_lookup.is_known);
        bench.print_result(r_lookup.contains_tx);
    }

    std.debug.print("\n" ++ "=" ** 100 ++ "\n\n", .{});
}

test "txpool benchmark main entrypoint is directly executable" {
    try main();
}
