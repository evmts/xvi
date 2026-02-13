const std = @import("std");
const primitives = @import("primitives");

const TxPool = @import("pool.zig").TxPool;
const AcceptTxResult = @import("accept_result.zig").AcceptTxResult;
const TransactionHash = primitives.TransactionHash.TransactionHash;
const TransactionType = primitives.Transaction.TransactionType;
const Address = primitives.Address;

/// Nethermind-parity duplicate filter for txpool admission.
///
/// Ordering mirrors `AlreadyKnownTxFilter`: prefer the hash-cache check, then
/// fall back to typed pool containment for concrete duplicate detection.
pub fn precheck_duplicate(
    pool: TxPool,
    tx_hash: TransactionHash,
    tx_type: TransactionType,
) AcceptTxResult {
    if (pool.is_known(tx_hash)) return AcceptTxResult.already_known;
    if (pool.contains_tx(tx_hash, tx_type)) return AcceptTxResult.already_known;
    pool.mark_known_for_current_scope(tx_hash);
    return AcceptTxResult.accepted;
}

test "precheck_duplicate rejects hash-cache hits without probing typed pools" {
    const DummyPool = struct {
        known_hash: TransactionHash,
        typed_hash: TransactionHash,
        typed_kind: TransactionType,
        is_known_calls: u32 = 0,
        contains_calls: u32 = 0,
        mark_calls: u32 = 0,

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
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.is_known_calls += 1;
            return std.mem.eql(u8, &self.known_hash, &tx_hash);
        }

        fn mark_known_for_current_scope(ptr: *anyopaque, _: TransactionHash) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.mark_calls += 1;
        }

        fn contains_tx(ptr: *anyopaque, tx_hash: TransactionHash, tx_type: TransactionType) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.contains_calls += 1;
            return std.mem.eql(u8, &self.typed_hash, &tx_hash) and self.typed_kind == tx_type;
        }
    };

    const known_hash: TransactionHash = [_]u8{0xAA} ** 32;
    const typed_hash: TransactionHash = [_]u8{0xBB} ** 32;
    var impl = DummyPool{
        .known_hash = known_hash,
        .typed_hash = typed_hash,
        .typed_kind = .eip1559,
    };

    const vtable = TxPool.VTable{
        .pending_count = DummyPool.pending_count,
        .pending_blob_count = DummyPool.pending_blob_count,
        .get_pending_transactions = DummyPool.get_pending_transactions,
        .supports_blobs = DummyPool.supports_blobs,
        .get_pending_count_for_sender = DummyPool.get_pending_count_for_sender,
        .get_pending_transactions_by_sender = DummyPool.get_pending_transactions_by_sender,
        .is_known = DummyPool.is_known,
        .mark_known_for_current_scope = DummyPool.mark_known_for_current_scope,
        .contains_tx = DummyPool.contains_tx,
    };
    const pool = TxPool{ .ptr = &impl, .vtable = &vtable };

    const result = precheck_duplicate(pool, known_hash, .legacy);
    try std.testing.expect(AcceptTxResult.eql(AcceptTxResult.already_known, result));
    try std.testing.expectEqual(@as(u32, 1), impl.is_known_calls);
    try std.testing.expectEqual(@as(u32, 0), impl.contains_calls);
    try std.testing.expectEqual(@as(u32, 0), impl.mark_calls);
}

test "precheck_duplicate matches typed containment semantics" {
    const DummyPool = struct {
        known_hash: TransactionHash,
        typed_hash: TransactionHash,
        typed_kind: TransactionType,
        mark_calls: u32 = 0,
        last_marked: TransactionHash = [_]u8{0} ** 32,

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
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return std.mem.eql(u8, &self.known_hash, &tx_hash);
        }

        fn mark_known_for_current_scope(ptr: *anyopaque, tx_hash: TransactionHash) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.mark_calls += 1;
            self.last_marked = tx_hash;
        }

        fn contains_tx(ptr: *anyopaque, tx_hash: TransactionHash, tx_type: TransactionType) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return std.mem.eql(u8, &self.typed_hash, &tx_hash) and self.typed_kind == tx_type;
        }
    };

    const known_hash: TransactionHash = [_]u8{0x01} ** 32;
    const typed_hash: TransactionHash = [_]u8{0x02} ** 32;
    var impl = DummyPool{
        .known_hash = known_hash,
        .typed_hash = typed_hash,
        .typed_kind = .eip4844,
    };

    const vtable = TxPool.VTable{
        .pending_count = DummyPool.pending_count,
        .pending_blob_count = DummyPool.pending_blob_count,
        .get_pending_transactions = DummyPool.get_pending_transactions,
        .supports_blobs = DummyPool.supports_blobs,
        .get_pending_count_for_sender = DummyPool.get_pending_count_for_sender,
        .get_pending_transactions_by_sender = DummyPool.get_pending_transactions_by_sender,
        .is_known = DummyPool.is_known,
        .mark_known_for_current_scope = DummyPool.mark_known_for_current_scope,
        .contains_tx = DummyPool.contains_tx,
    };
    const pool = TxPool{ .ptr = &impl, .vtable = &vtable };

    const typed_duplicate = precheck_duplicate(pool, typed_hash, .eip4844);
    try std.testing.expect(AcceptTxResult.eql(AcceptTxResult.already_known, typed_duplicate));

    const other_typed = precheck_duplicate(pool, typed_hash, .legacy);
    try std.testing.expect(AcceptTxResult.eql(AcceptTxResult.accepted, other_typed));
    try std.testing.expectEqual(@as(u32, 1), impl.mark_calls);
    try std.testing.expectEqualDeep(typed_hash, impl.last_marked);

    const fresh = precheck_duplicate(pool, [_]u8{0x03} ** 32, .legacy);
    try std.testing.expect(AcceptTxResult.eql(AcceptTxResult.accepted, fresh));
    try std.testing.expectEqual(@as(u32, 2), impl.mark_calls);
    try std.testing.expectEqualDeep([_]u8{0x03} ** 32, impl.last_marked);
}
