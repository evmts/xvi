const std = @import("std");
const primitives = @import("primitives");

const tx_mod = primitives.Transaction;
const TxPoolConfig = @import("pool.zig").TxPoolConfig;
const U256 = primitives.Denomination.U256;
const GasLimit = primitives.Gas.GasLimit;
const Address = primitives.Address;

inline fn assert_supported_tx_type(comptime T: type, comptime fn_name: []const u8) void {
    if (!(T == tx_mod.LegacyTransaction or
        T == tx_mod.Eip1559Transaction or
        T == tx_mod.Eip4844Transaction or
        T == tx_mod.Eip7702Transaction))
    {
        @compileError("Unsupported transaction type for " ++ fn_name ++ ": " ++ @typeName(T));
    }
}
// -----------------------------------------------------------------------------
// Internal helpers (no allocations)
// -----------------------------------------------------------------------------
/// Return true when a typed transaction contains a signature (y_parity,r,s).
inline fn has_signature(y_parity: anytype, r: [32]u8, s: [32]u8) bool {
    comptime {
        if (!(@typeInfo(@TypeOf(y_parity)) == .int and @typeInfo(@TypeOf(y_parity)).int.signedness == .unsigned))
            @compileError("has_signature expects an unsigned integer y_parity");
    }
    const zeros = [_]u8{0} ** 32;
    return !(y_parity == 0 and std.mem.eql(u8, &r, &zeros) and std.mem.eql(u8, &s, &zeros));
}

/// Compute RLP-encoded length of an AccessList without allocations.
inline fn rlp_len_of_access_list(list: []const tx_mod.AccessListItem) usize {
    var items_total: usize = 0;
    for (list) |it| {
        // AccessListItem = [ address: B_20, storage_keys: [B_32, ...] ]
        const addr_len = rlp_len_of_bytes(20, null);

        var keys_items_total: usize = 0;
        for (it.storage_keys) |_| {
            keys_items_total += rlp_len_of_bytes(32, null);
        }
        const keys_list_len = rlp_len_of_list(keys_items_total);

        const item_payload = addr_len + keys_list_len;
        items_total += rlp_len_of_list(item_payload);
    }
    return rlp_len_of_list(items_total);
}

/// Compute RLP-encoded length of a nullable `to` field.
inline fn rlp_len_of_optional_to(to: ?Address) usize {
    return if (to != null) rlp_len_of_bytes(20, null) else rlp_len_of_bytes(0, null);
}

/// Compute RLP-encoded length of a calldata bytes field.
inline fn rlp_len_of_data(data: []const u8) usize {
    const first: ?u8 = if (data.len == 1) data[0] else null;
    return rlp_len_of_bytes(data.len, first);
}

/// Compute RLP-encoded length of a `(parity_or_v, r, s)` signature triplet.
inline fn rlp_len_of_signature_triplet(parity_or_v: anytype) usize {
    return rlp_len_of_uint(parity_or_v) +
        rlp_len_of_bytes(32, null) +
        rlp_len_of_bytes(32, null);
}

/// Compute final length for typed transaction envelopes (`type || rlp(payload)`).
inline fn rlp_len_of_typed_tx(payload_len: usize) usize {
    return 1 + rlp_len_of_list(payload_len);
}

// -----------------------------------------------------------------------------
// Public helpers (no allocations)
// -----------------------------------------------------------------------------
/// Validate a transaction's `gas_limit` against optional pool cap.
///
/// - If `cfg.gas_limit` is `null`, this check is a no-op.
/// - Otherwise returns `error.TxGasLimitExceeded` when `tx.gas_limit > cfg.gas_limit`.
///
/// Uses Voltaire primitives exclusively. Applies uniformly to all canonical
/// transaction types (legacy, 1559, 4844, 7702).
pub fn fits_gas_limit(tx: anytype, cfg: TxPoolConfig) error{TxGasLimitExceeded}!void {
    const T = @TypeOf(tx);
    comptime {
        assert_supported_tx_type(T, "fits_gas_limit");
    }

    const cap_opt = cfg.gas_limit;
    if (cap_opt) |cap| {
        // Compare using Voltaire GasLimit semantics without lossy casts.
        // Convert tx.gas_limit (u64) into a GasLimit and compare underlying Uint.
        const tx_limit_gl = GasLimit.from_u64(@intCast(tx.gas_limit));
        if (tx_limit_gl.value.gt(cap.value)) return error.TxGasLimitExceeded;
    }
}

/// Enforce that a transaction's nonce is not too far in the future
/// relative to the sender's current account nonce and the number of
/// already-pending transactions from that sender.
///
/// Mirrors Nethermind's GapNonceFilter core predicate:
///   next_nonce_in_order = current_nonce + pending_sender_txs
///   accept if tx_nonce <= next_nonce_in_order
///
/// Notes:
/// - This helper ONLY checks for a future gap; it does not reject stale
///   (too-low) nonces. Other admission stages should handle stale/replacement.
/// - Uses difference arithmetic to avoid `u64` overflow on addition.
pub fn enforce_nonce_gap(
    tx_nonce: u64,
    current_nonce: u64,
    pending_sender_txs: u32,
) error{NonceGap}!void {
    // If tx is not ahead of current nonce, gap filter is satisfied.
    if (tx_nonce <= current_nonce) return;

    // Compute forward distance using subtraction to avoid overflow.
    const forward: u64 = tx_nonce - current_nonce;

    // Accept if tx is within the allowed window: distance ≤ pending count.
    if (forward <= @as(u64, @intCast(pending_sender_txs))) return;

    return error.NonceGap;
}

test "enforce_nonce_gap — accepts when nonce <= current" {
    try enforce_nonce_gap(7, 8, 0);
}

test "enforce_nonce_gap — accepts when within pending window" {
    // current=10, pending=3 allows up to nonce=13
    try enforce_nonce_gap(11, 10, 3);
    try enforce_nonce_gap(13, 10, 3);
}

test "enforce_nonce_gap — rejects when beyond pending window" {
    try std.testing.expectError(error.NonceGap, enforce_nonce_gap(14, 10, 3));
}

test "enforce_nonce_gap — handles near-overflow arithmetic safely" {
    const near_max = std.math.maxInt(u64) - 1;
    try enforce_nonce_gap(std.math.maxInt(u64), near_max, 1);
    try std.testing.expectError(error.NonceGap, enforce_nonce_gap(std.math.maxInt(u64), near_max, 0));
}
/// Validate the RLP-encoded size of a transaction against pool limits.
///
/// - Uses Voltaire Transaction encoders to compute raw network bytes:
///   - Legacy: RLP(list [...])
///   - EIP-1559 / EIP-7702: 1-byte type prefix + RLP(list [...])
///   - EIP-4844: 1-byte type prefix + RLP(list [...]) — blobs not included
/// - Applies `cfg.max_blob_tx_size` to blob txs (EIP-4844), else `cfg.max_tx_size`.
/// - Returns an error when the encoded size exceeds the configured limit.
pub fn fits_size_limits(
    tx: anytype,
    cfg: TxPoolConfig,
) error{ MaxTxSizeExceeded, MaxBlobTxSizeExceeded }!void {
    const T = @TypeOf(tx);
    comptime {
        assert_supported_tx_type(T, "fits_size_limits");
    }

    var len: usize = 0;
    if (comptime T == tx_mod.LegacyTransaction) {
        // Allocation-free, wire-accurate legacy RLP sizing (always includes v,r,s)
        var payload_len: usize = 0;
        payload_len += rlp_len_of_uint(tx.nonce);
        payload_len += rlp_len_of_uint(tx.gas_price);
        payload_len += rlp_len_of_uint(tx.gas_limit);
        payload_len += rlp_len_of_optional_to(tx.to);
        payload_len += rlp_len_of_uint(tx.value);
        payload_len += rlp_len_of_data(tx.data);
        // Signature fields are part of the on-wire encoding
        payload_len += rlp_len_of_signature_triplet(tx.v);
        len = rlp_len_of_list(payload_len);
    } else if (comptime T == tx_mod.Eip1559Transaction) {
        // Allocation-free, wire-accurate typed-2 sizing (always includes y_parity,r,s)
        var payload_len: usize = 0;
        payload_len += rlp_len_of_uint(tx.chain_id);
        payload_len += rlp_len_of_uint(tx.nonce);
        payload_len += rlp_len_of_uint(tx.max_priority_fee_per_gas);
        payload_len += rlp_len_of_uint(tx.max_fee_per_gas);
        payload_len += rlp_len_of_uint(tx.gas_limit);
        payload_len += rlp_len_of_optional_to(tx.to);
        payload_len += rlp_len_of_uint(tx.value);
        payload_len += rlp_len_of_data(tx.data);
        payload_len += rlp_len_of_access_list(tx.access_list);
        // Always account for signature triplet for on-wire size
        payload_len += rlp_len_of_signature_triplet(tx.y_parity);
        len = rlp_len_of_typed_tx(payload_len);
    } else if (comptime T == tx_mod.Eip4844Transaction) {
        // Length-only sizing for EIP-4844 to minimize allocations.
        var payload_len: usize = 0;
        payload_len += rlp_len_of_uint(tx.chain_id);
        payload_len += rlp_len_of_uint(tx.nonce);
        payload_len += rlp_len_of_uint(tx.max_priority_fee_per_gas);
        payload_len += rlp_len_of_uint(tx.max_fee_per_gas);
        payload_len += rlp_len_of_uint(tx.gas_limit);
        // to: EIP-4844 disallows contract creation, so `to` is always present
        payload_len += rlp_len_of_bytes(20, null);
        // value
        payload_len += rlp_len_of_uint(tx.value);
        // data
        payload_len += rlp_len_of_data(tx.data);
        // access_list (length-only)
        payload_len += rlp_len_of_access_list(tx.access_list);
        // max_fee_per_blob_gas
        payload_len += rlp_len_of_uint(tx.max_fee_per_blob_gas);
        // blob_versioned_hashes: each hash is 32 bytes → RLP item length fixed
        const per_hash_len: usize = rlp_len_of_bytes(32, null);
        const hashes_items_len: usize = tx.blob_versioned_hashes.len * per_hash_len;
        payload_len += rlp_len_of_list(hashes_items_len);

        // Optional signature: y_parity, r, s
        if (has_signature(tx.y_parity, tx.r, tx.s)) {
            payload_len += rlp_len_of_signature_triplet(tx.y_parity);
        }

        // Type prefix (0x03) + RLP(list header+payload). Blobs are NOT included.
        len = rlp_len_of_typed_tx(payload_len);
    } else if (comptime T == tx_mod.Eip7702Transaction) {
        // Length-only sizing for EIP-7702 (typed-4) to minimize allocations.
        var payload_len: usize = 0;
        // chain_id, nonce, fees, gas_limit
        payload_len += rlp_len_of_uint(tx.chain_id);
        payload_len += rlp_len_of_uint(tx.nonce);
        payload_len += rlp_len_of_uint(tx.max_priority_fee_per_gas);
        payload_len += rlp_len_of_uint(tx.max_fee_per_gas);
        payload_len += rlp_len_of_uint(tx.gas_limit);

        // to (nullable)
        payload_len += rlp_len_of_optional_to(tx.to);

        // value, data
        payload_len += rlp_len_of_uint(tx.value);
        payload_len += rlp_len_of_data(tx.data);

        // access_list (length-only)
        payload_len += rlp_len_of_access_list(tx.access_list);

        // authorization_list — compute length-only with y_parity derived from v
        var auth_items_encoded_total: usize = 0;
        for (tx.authorization_list) |auth| {
            var auth_payload: usize = 0;
            auth_payload += rlp_len_of_uint(auth.chain_id);
            auth_payload += rlp_len_of_bytes(20, null);
            auth_payload += rlp_len_of_uint(auth.nonce);
            const y_parity: u8 = if (auth.v == 27) 0 else if (auth.v == 28) 1 else @as(u8, @intCast(auth.v & 1));
            auth_payload += rlp_len_of_uint(y_parity);
            auth_payload += rlp_len_of_bytes(32, null); // r
            auth_payload += rlp_len_of_bytes(32, null); // s
            auth_items_encoded_total += rlp_len_of_list(auth_payload);
        }
        payload_len += rlp_len_of_list(auth_items_encoded_total);

        // Optional transaction signature (y_parity, r, s)
        if (has_signature(tx.y_parity, tx.r, tx.s)) {
            payload_len += rlp_len_of_signature_triplet(tx.y_parity);
        }

        // Final typed envelope size
        len = rlp_len_of_typed_tx(payload_len);
    }
    // EIP-4844: Prefer specific blob-envelope limit when configured;
    // otherwise, fall back to the generic `max_tx_size` check below.
    if (comptime T == tx_mod.Eip4844Transaction) {
        if (cfg.max_blob_tx_size) |max| {
            if (len > max) return error.MaxBlobTxSizeExceeded;
            // When a blob-specific cap exists, do not apply the generic cap.
            return;
        }
        // No blob cap configured — intentionally fall through to generic cap.
    }

    if (cfg.max_tx_size) |max| {
        if (len > max) return error.MaxTxSizeExceeded;
    }
}
/// - If the transaction is not an EIP-4844 blob transaction, this is a no-op.
/// - When `cfg.min_blob_tx_priority_fee > 0`, require
///   `tx.max_priority_fee_per_gas >= cfg.min_blob_tx_priority_fee`.
/// - When `cfg.current_blob_base_fee_required` is true, require
///   `tx.max_fee_per_blob_gas >= current_blob_base_fee`.
///
/// Uses only Voltaire primitives. This helper is intentionally strict and
/// does not attempt to coerce types beyond primitives' own conversions.
pub fn enforce_min_priority_fee_for_blobs(
    tx: anytype,
    cfg: TxPoolConfig,
    current_blob_base_fee: U256,
) error{ BlobPriorityFeeTooLow, InsufficientMaxFeePerBlobGas }!void {
    const T = @TypeOf(tx);
    comptime {
        assert_supported_tx_type(T, "enforce_min_priority_fee_for_blobs");
    }

    // Only applies to blob transactions (EIP-4844, type-3)
    if (comptime T != tx_mod.Eip4844Transaction) return;

    // Check min priority fee for blob txs (if configured > 0)
    if (!cfg.min_blob_tx_priority_fee.isZero()) {
        // Compare in wei space using primitives types.
        const tx_tip_wei: U256 = U256.from_u256(tx.max_priority_fee_per_gas);
        const min_tip_wei: U256 = cfg.min_blob_tx_priority_fee.toWei();
        if (tx_tip_wei.cmp(min_tip_wei) == .lt) {
            return error.BlobPriorityFeeTooLow;
        }
    }

    // Require max_fee_per_blob_gas ≥ current blob base fee if enabled.
    if (cfg.current_blob_base_fee_required) {
        const tx_blob_max_wei: U256 = U256.from_u256(tx.max_fee_per_blob_gas);
        if (tx_blob_max_wei.cmp(current_blob_base_fee) == .lt) {
            return error.InsufficientMaxFeePerBlobGas;
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

fn append_rlp_list_prefix(
    allocator: std.mem.Allocator,
    out: *std.array_list.AlignedManaged(u8, null),
    payload_len: usize,
) !void {
    const rlp = primitives.Rlp;
    if (payload_len <= 55) {
        try out.append(@as(u8, @intCast(0xc0 + payload_len)));
        return;
    }

    const len_bytes = try rlp.encodeLength(allocator, payload_len);
    defer allocator.free(len_bytes);
    try out.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
    try out.appendSlice(len_bytes);
}

fn make_typed_envelope(
    allocator: std.mem.Allocator,
    tx_type: u8,
    rlp_payload_list: []const u8,
) ![]u8 {
    const encoded = try allocator.alloc(u8, 1 + rlp_payload_list.len);
    encoded[0] = tx_type;
    @memcpy(encoded[1..], rlp_payload_list);
    return encoded;
}

test "fits_size_limits — legacy within and over limit (wire size incl. v,r,s)" {
    const tx = tx_mod.LegacyTransaction{
        .nonce = 0,
        .gas_price = 1,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .v = 37,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    // Compute expected wire size manually: full signed legacy tx RLP
    const allocator = std.testing.allocator;
    const rlp = primitives.Rlp;
    var list = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer list.deinit();
    {
        const enc = try rlp.encode(allocator, tx.nonce);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.gas_price);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.gas_limit);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.to.?.bytes);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.value);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, tx.data);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.v);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.r);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.s);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    var wrapped = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer wrapped.deinit();
    try append_rlp_list_prefix(allocator, &wrapped, list.items.len);
    try wrapped.appendSlice(list.items);
    const encoded = wrapped.items;

    var cfg_ok = TxPoolConfig{}; // defaults allow ample size
    cfg_ok.max_tx_size = encoded.len; // exactly fits
    try fits_size_limits(tx, cfg_ok);

    var cfg_bad = TxPoolConfig{};
    cfg_bad.max_tx_size = encoded.len - 1; // too small
    try std.testing.expectError(error.MaxTxSizeExceeded, fits_size_limits(tx, cfg_bad));
}

test "fits_size_limits — eip1559 within and over limit (wire size incl. y_parity,r,s)" {
    const tx = tx_mod.Eip1559Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        // mark as signed to reflect network encoding size (include v,r,s)
        .y_parity = 1,
        .r = [_]u8{1} ** 32,
        .s = [_]u8{2} ** 32,
    };

    const allocator = std.testing.allocator;
    // Build full typed-2 bytes manually to assert true wire size
    const rlp = primitives.Rlp;
    var list = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer list.deinit();
    {
        const enc = try rlp.encode(allocator, tx.chain_id);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.nonce);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_priority_fee_per_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_fee_per_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.gas_limit);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.to.?.bytes);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.value);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, tx.data);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try tx_mod.encodeAccessList(allocator, tx.access_list);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.y_parity);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.r);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.s);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    var wrapped = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer wrapped.deinit();
    try append_rlp_list_prefix(allocator, &wrapped, list.items.len);
    try wrapped.appendSlice(list.items);
    const encoded = try make_typed_envelope(allocator, 0x02, wrapped.items);
    defer allocator.free(encoded);

    var cfg_ok = TxPoolConfig{};
    cfg_ok.max_tx_size = encoded.len;
    try fits_size_limits(tx, cfg_ok);

    var cfg_bad = TxPoolConfig{};
    cfg_bad.max_tx_size = encoded.len - 1;
    try std.testing.expectError(error.MaxTxSizeExceeded, fits_size_limits(tx, cfg_bad));
}

test "fits_size_limits — eip4844 (blob) within and over blob limit" {
    const VersionedHash = primitives.Blob.VersionedHash;

    const hashes = [_]VersionedHash{.{ .bytes = [_]u8{0xAA} ++ [_]u8{0} ** 31 }};

    const tx = tx_mod.Eip4844Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0x33} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
        // mark as signed to reflect network encoding size (include y_parity,r,s)
        .y_parity = 1,
        .r = [_]u8{3} ** 32,
        .s = [_]u8{4} ** 32,
    };

    const allocator = std.testing.allocator;
    // Compute encoded length using the same manual RLP path as implementation
    const rlp = primitives.Rlp;
    var list = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer list.deinit();
    {
        const enc = try rlp.encode(allocator, tx.chain_id);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.nonce);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_priority_fee_per_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_fee_per_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.gas_limit);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.to.bytes);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.value);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, tx.data);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try tx_mod.encodeAccessList(allocator, tx.access_list);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_fee_per_blob_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        var hashes_list = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer hashes_list.deinit();
        for (tx.blob_versioned_hashes) |vh| {
            const enc = try rlp.encodeBytes(allocator, &vh.bytes);
            defer allocator.free(enc);
            try hashes_list.appendSlice(enc);
        }
        try append_rlp_list_prefix(allocator, &list, hashes_list.items.len);
        try list.appendSlice(hashes_list.items);
    }
    {
        const enc = try rlp.encode(allocator, tx.y_parity);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.r);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.s);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }

    var wrapped = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer wrapped.deinit();
    try append_rlp_list_prefix(allocator, &wrapped, list.items.len);
    try wrapped.appendSlice(list.items);

    const encoded = try make_typed_envelope(allocator, 0x03, wrapped.items);
    defer allocator.free(encoded);

    var cfg_ok = TxPoolConfig{};
    cfg_ok.max_blob_tx_size = encoded.len;
    try fits_size_limits(tx, cfg_ok);

    var cfg_bad = TxPoolConfig{};
    cfg_bad.max_blob_tx_size = encoded.len - 1;
    try std.testing.expectError(error.MaxBlobTxSizeExceeded, fits_size_limits(tx, cfg_bad));
}

test "fits_size_limits — eip7702 within and over limit (unsigned)" {
    const Authorization = primitives.Authorization.Authorization;
    const tx = tx_mod.Eip7702Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0x44} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .authorization_list = &[_]Authorization{},
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
        .y_parity = 0,
    };

    const allocator = std.testing.allocator;
    // Mirror manual encoding used in implementation to compute expected length
    const rlp = primitives.Rlp;
    var list = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer list.deinit();
    {
        const enc = try rlp.encode(allocator, tx.chain_id);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.nonce);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_priority_fee_per_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_fee_per_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.gas_limit);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    if (tx.to) |to_addr| {
        const enc = try rlp.encodeBytes(allocator, &to_addr.bytes);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    } else {
        try list.append(0x80);
    }
    {
        const enc = try rlp.encode(allocator, tx.value);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, tx.data);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try tx_mod.encodeAccessList(allocator, tx.access_list);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        std.debug.assert(tx.authorization_list.len == 0);
        // Empty authorization list is encoded as an empty RLP list (0xc0).
        try list.append(0xc0);
    }
    var wrapped = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer wrapped.deinit();
    try append_rlp_list_prefix(allocator, &wrapped, list.items.len);
    try wrapped.appendSlice(list.items);
    const encoded = try make_typed_envelope(allocator, 0x04, wrapped.items);
    defer allocator.free(encoded);

    var cfg_ok = TxPoolConfig{};
    cfg_ok.max_tx_size = encoded.len;
    try fits_size_limits(tx, cfg_ok);

    var cfg_bad = TxPoolConfig{};
    cfg_bad.max_tx_size = encoded.len - 1;
    try std.testing.expectError(error.MaxTxSizeExceeded, fits_size_limits(tx, cfg_bad));
}

test "fits_size_limits — eip7702 within and over limit (signed)" {
    const Authorization = primitives.Authorization.Authorization;
    var tx = tx_mod.Eip7702Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0x55} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .authorization_list = &[_]Authorization{},
        .y_parity = 1,
        .r = [_]u8{9} ** 32,
        .s = [_]u8{8} ** 32,
    };

    const allocator = std.testing.allocator;
    // Mirror manual encoding used in implementation to compute expected length (with signature)
    const rlp = primitives.Rlp;
    var list = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer list.deinit();
    {
        const enc = try rlp.encode(allocator, tx.chain_id);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.nonce);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_priority_fee_per_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.max_fee_per_gas);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encode(allocator, tx.gas_limit);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    if (tx.to) |to_addr| {
        const enc = try rlp.encodeBytes(allocator, &to_addr.bytes);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    } else {
        try list.append(0x80);
    }
    {
        const enc = try rlp.encode(allocator, tx.value);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, tx.data);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try tx_mod.encodeAccessList(allocator, tx.access_list);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        std.debug.assert(tx.authorization_list.len == 0);
        // Empty authorization list is encoded as an empty RLP list (0xc0).
        try list.append(0xc0);
    }
    // include y_parity, r, s
    {
        const enc = try rlp.encode(allocator, tx.y_parity);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.r);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    {
        const enc = try rlp.encodeBytes(allocator, &tx.s);
        defer allocator.free(enc);
        try list.appendSlice(enc);
    }
    var wrapped = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer wrapped.deinit();
    try append_rlp_list_prefix(allocator, &wrapped, list.items.len);
    try wrapped.appendSlice(list.items);
    const encoded = try make_typed_envelope(allocator, 0x04, wrapped.items);
    defer allocator.free(encoded);

    var cfg_ok = TxPoolConfig{};
    cfg_ok.max_tx_size = encoded.len;
    try fits_size_limits(tx, cfg_ok);

    var cfg_bad = TxPoolConfig{};
    cfg_bad.max_tx_size = encoded.len - 1;
    try std.testing.expectError(error.MaxTxSizeExceeded, fits_size_limits(tx, cfg_bad));
}

test "fits_gas_limit — passes when under/equal, errors when over (legacy)" {
    const tx = tx_mod.LegacyTransaction{
        .nonce = 0,
        .gas_price = 1,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0x99} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .v = 37,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    // No cap → always OK
    try fits_gas_limit(tx, TxPoolConfig{});

    var cfg = TxPoolConfig{};
    cfg.gas_limit = GasLimit.from_u64(21_000);
    try fits_gas_limit(tx, cfg); // equal → OK

    cfg.gas_limit = GasLimit.from_u64(20_999);
    try std.testing.expectError(error.TxGasLimitExceeded, fits_gas_limit(tx, cfg));
}

test "fits_gas_limit — works for typed txs (1559, 4844, 7702)" {
    const VersionedHash = primitives.Blob.VersionedHash;
    const Authorization = primitives.Authorization.Authorization;

    var cfg = TxPoolConfig{};
    cfg.gas_limit = GasLimit.from_u64(50_000);

    const tx1559 = tx_mod.Eip1559Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 30_000,
        .to = Address{ .bytes = [_]u8{0xA1} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .y_parity = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    try fits_gas_limit(tx1559, cfg);

    const hashes = [_]VersionedHash{.{ .bytes = [_]u8{0xAB} ++ [_]u8{0} ** 31 }};
    const tx4844 = tx_mod.Eip4844Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 60_000, // above cap
        .to = Address{ .bytes = [_]u8{0xA2} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
        .y_parity = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    try std.testing.expectError(error.TxGasLimitExceeded, fits_gas_limit(tx4844, cfg));

    const tx7702 = tx_mod.Eip7702Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 50_000, // equal to cap
        .to = Address{ .bytes = [_]u8{0xA3} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .authorization_list = &[_]Authorization{},
        .y_parity = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    try fits_gas_limit(tx7702, cfg);
}

test "enforce_min_priority_fee_for_blobs — no-op for non-blob txs" {
    const tx = tx_mod.Eip1559Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 0,
        .max_fee_per_gas = 0,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0xE1} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .y_parity = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const cfg = TxPoolConfig{};
    try enforce_min_priority_fee_for_blobs(tx, cfg, U256.ZERO);
}

test "enforce_min_priority_fee_for_blobs — blob base fee required enforced" {
    const VersionedHash = primitives.Blob.VersionedHash;
    const hashes = [_]VersionedHash{.{ .bytes = [_]u8{0xB1} ++ [_]u8{0} ** 31 }};

    // Tx with max_fee_per_blob_gas below the supplied base fee.
    var cfg = TxPoolConfig{};
    cfg.current_blob_base_fee_required = true;

    const tx_low = tx_mod.Eip4844Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0xE2} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .max_fee_per_blob_gas = 4,
        .blob_versioned_hashes = &hashes,
        .y_parity = 1,
        .r = [_]u8{3} ** 32,
        .s = [_]u8{4} ** 32,
    };

    const base_fee = U256.from_u64(5);
    try std.testing.expectError(error.InsufficientMaxFeePerBlobGas, enforce_min_priority_fee_for_blobs(tx_low, cfg, base_fee));

    const tx_ok = tx_mod.Eip4844Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0xE3} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .max_fee_per_blob_gas = 5,
        .blob_versioned_hashes = &hashes,
        .y_parity = 1,
        .r = [_]u8{5} ** 32,
        .s = [_]u8{6} ** 32,
    };
    try enforce_min_priority_fee_for_blobs(tx_ok, cfg, base_fee);
}

test "enforce_min_priority_fee_for_blobs — min priority tip enforced for blob txs" {
    const VersionedHash = primitives.Blob.VersionedHash;
    const hashes = [_]VersionedHash{.{ .bytes = [_]u8{0xB2} ++ [_]u8{0} ** 31 }};

    var cfg = TxPoolConfig{};
    cfg.current_blob_base_fee_required = false; // isolate priority fee check
    const MaxPriorityFeePerGas = primitives.MaxPriorityFeePerGas;
    cfg.min_blob_tx_priority_fee = MaxPriorityFeePerGas.from(3);
    const tx_low = tx_mod.Eip4844Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 2, // below min (3)
        .max_fee_per_gas = 10,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0xE4} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
        .y_parity = 1,
        .r = [_]u8{7} ** 32,
        .s = [_]u8{8} ** 32,
    };
    try std.testing.expectError(error.BlobPriorityFeeTooLow, enforce_min_priority_fee_for_blobs(tx_low, cfg, U256.ZERO));

    const tx_ok = tx_mod.Eip4844Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 3, // equal to min
        .max_fee_per_gas = 10,
        .gas_limit = 21_000,
        .to = Address{ .bytes = [_]u8{0xE5} ++ [_]u8{0} ** 19 },
        .value = 0,
        .data = &[_]u8{},
        .access_list = &[_]tx_mod.AccessListItem{},
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
        .y_parity = 1,
        .r = [_]u8{9} ** 32,
        .s = [_]u8{10} ** 32,
    };
    try enforce_min_priority_fee_for_blobs(tx_ok, cfg, U256.ZERO);
}

// -----------------------------------------------------------------------------
// Lightweight RLP length helpers (no allocations)
// -----------------------------------------------------------------------------
inline fn rlp_len_of_list(payload_len: usize) usize {
    // 0xC0 + len (<=55) OR 0xF7 + len_of_len + len
    if (payload_len <= 55) return 1 + payload_len;
    var tmp = payload_len;
    var n: usize = 0;
    while (tmp > 0) : (tmp >>= 8) n += 1;
    return 1 + n + payload_len;
}

inline fn rlp_len_of_bytes(len: usize, first_byte_if_len1: ?u8) usize {
    // If a single byte less than 0x80, encoded as itself
    if (len == 1) {
        if (first_byte_if_len1) |b| if (b < 0x80) return 1;
        // Otherwise short string form (0x80 + 1 + byte)
        return 2;
    }
    if (len < 56) return 1 + len;
    var tmp = len;
    var n: usize = 0;
    while (tmp > 0) : (tmp >>= 8) n += 1;
    return 1 + n + len;
}

inline fn rlp_len_of_uint(x: anytype) usize {
    const T = @TypeOf(x);
    comptime {
        if (!(@typeInfo(T) == .int and @typeInfo(T).int.signedness == .unsigned))
            @compileError("rlp_len_of_uint expects an unsigned integer type");
    }
    if (x == 0) return 1; // encoded as empty string (0x80)
    // Determine minimal byte length via bit-length to avoid shifts on small ints.
    const bits: usize = @bitSizeOf(T);
    const used_bits: usize = bits - @clz(x);
    const bytes: usize = (used_bits + 7) / 8;
    if (bytes == 1 and (x & 0x7f) == x) return 1; // single byte < 0x80
    return 1 + bytes; // short string form
}
