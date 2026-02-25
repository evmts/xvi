/// Transaction pool sorting helpers (fee market priority).
///
/// Spec references:
/// - EIP-1559 effective gas price calculation
/// - execution-specs/src/ethereum/forks/london/fork.py (effective gas price)
///
/// Nethermind reference:
/// - Nethermind.Consensus/Comparers/GasPriceTxComparerHelper.cs
const std = @import("std");
const primitives = @import("voltaire");

const BaseFeePerGas = primitives.BaseFeePerGas;
const GasPrice = primitives.GasPrice;
const MaxFeePerGas = primitives.MaxFeePerGas;
const MaxPriorityFeePerGas = primitives.MaxPriorityFeePerGas;
const U256 = primitives.Denomination.U256;

fn is_legacy_fee_fields(max_fee: MaxFeePerGas, max_priority: MaxPriorityFeePerGas) bool {
    return max_fee.isZero() and max_priority.isZero();
}

const ResolvedFeeTuple = struct {
    max_fee: MaxFeePerGas,
    max_priority: MaxPriorityFeePerGas,
};

fn resolve_fee_tuple(
    gas_price: GasPrice,
    max_fee: MaxFeePerGas,
    max_priority: MaxPriorityFeePerGas,
) ResolvedFeeTuple {
    if (!is_legacy_fee_fields(max_fee, max_priority)) {
        return .{
            .max_fee = max_fee,
            .max_priority = max_priority,
        };
    }

    const legacy_fee_wei = gas_price.toWei();
    return .{
        .max_fee = MaxFeePerGas.fromU256(legacy_fee_wei),
        .max_priority = MaxPriorityFeePerGas.fromU256(legacy_fee_wei),
    };
}

inline fn min_u256(a: U256, b: U256) U256 {
    return if (a.cmp(b) == .gt) b else a;
}

/// Returns EIP-1559 effective gas price: `min(max_fee, base_fee + min(max_priority, max_fee - base_fee))`.
///
/// For `max_fee <= base_fee`, this returns `max_fee` directly. This keeps arithmetic
/// overflow-proof for extreme synthetic inputs while preserving consensus math.
fn effective_gas_price(base_fee_wei: U256, fee: ResolvedFeeTuple) U256 {
    const max_fee_wei = fee.max_fee.toWei();
    if (max_fee_wei.cmp(base_fee_wei) != .gt) return max_fee_wei;

    const max_priority_wei = fee.max_priority.toWei();
    const allowed_priority = max_fee_wei.wrapping_sub(base_fee_wei);
    const effective_priority = min_u256(max_priority_wei, allowed_priority);

    // Safe by construction: effective_priority <= (max_fee_wei - base_fee_wei).
    return base_fee_wei.wrapping_add(effective_priority);
}

/// Compare two fee tuples by priority (descending).
///
/// Returns:
/// - `-1` when `x` has higher priority (should sort before `y`)
/// - `0` when equal
/// - `1` when `y` has higher priority
///
/// When EIP-1559 is enabled, this compares the effective gas price:
/// `min(max_fee, base_fee + max_priority)` with a max fee tie-breaker.
/// Legacy txs with zeroed EIP-1559 fields are treated as
/// `max_fee = max_priority = gas_price`.
/// Otherwise it compares legacy `gas_price` (descending).
pub fn compare_fee_market_priority(
    x_gas_price: GasPrice,
    x_max_fee_per_gas: MaxFeePerGas,
    x_max_priority_fee_per_gas: MaxPriorityFeePerGas,
    y_gas_price: GasPrice,
    y_max_fee_per_gas: MaxFeePerGas,
    y_max_priority_fee_per_gas: MaxPriorityFeePerGas,
    base_fee: BaseFeePerGas,
    is_eip1559_enabled: bool,
) i32 {
    if (is_eip1559_enabled) {
        const x_fee = resolve_fee_tuple(x_gas_price, x_max_fee_per_gas, x_max_priority_fee_per_gas);
        const y_fee = resolve_fee_tuple(y_gas_price, y_max_fee_per_gas, y_max_priority_fee_per_gas);

        const base_fee_wei = base_fee.toWei();

        const x_effective = effective_gas_price(base_fee_wei, x_fee);
        const y_effective = effective_gas_price(base_fee_wei, y_fee);

        switch (x_effective.cmp(y_effective)) {
            .lt => return 1,
            .gt => return -1,
            .eq => {},
        }

        switch (x_fee.max_fee.compare(y_fee.max_fee)) {
            .lt => return 1,
            .gt => return -1,
            .eq => return 0,
        }
    }

    switch (x_gas_price.compare(y_gas_price)) {
        .lt => return 1,
        .gt => return -1,
        .eq => return 0,
    }
}

// =============================================================================
// Tests
// =============================================================================

test "compare_fee_market_priority — EIP-1559 compares effective gas price" {
    const base_fee = BaseFeePerGas.from(10_000_000_000);

    const x_max_fee = MaxFeePerGas.from(30_000_000_000);
    const x_max_priority = MaxPriorityFeePerGas.from(2_000_000_000);

    const y_max_fee = MaxFeePerGas.from(20_000_000_000);
    const y_max_priority = MaxPriorityFeePerGas.from(8_000_000_000);

    const x_gas_price = GasPrice.from(0);
    const y_gas_price = GasPrice.from(0);

    try std.testing.expectEqual(
        @as(i32, 1),
        compare_fee_market_priority(
            x_gas_price,
            x_max_fee,
            x_max_priority,
            y_gas_price,
            y_max_fee,
            y_max_priority,
            base_fee,
            true,
        ),
    );
}

test "compare_fee_market_priority — EIP-1559 legacy fallback uses gas price" {
    const base_fee = BaseFeePerGas.from(10_000_000_000);

    const x_gas_price = GasPrice.from(50_000_000_000);
    const x_max_fee = MaxFeePerGas.from(0);
    const x_max_priority = MaxPriorityFeePerGas.from(0);

    const y_gas_price = GasPrice.from(0);
    const y_max_fee = MaxFeePerGas.from(40_000_000_000);
    const y_max_priority = MaxPriorityFeePerGas.from(2_000_000_000);

    try std.testing.expectEqual(
        @as(i32, -1),
        compare_fee_market_priority(
            x_gas_price,
            x_max_fee,
            x_max_priority,
            y_gas_price,
            y_max_fee,
            y_max_priority,
            base_fee,
            true,
        ),
    );
}

test "compare_fee_market_priority — EIP-1559 ties on effective gas price use max fee" {
    const base_fee = BaseFeePerGas.from(10_000_000_000);

    const x_max_fee = MaxFeePerGas.from(20_000_000_000);
    const x_max_priority = MaxPriorityFeePerGas.from(5_000_000_000);

    const y_max_fee = MaxFeePerGas.from(25_000_000_000);
    const y_max_priority = MaxPriorityFeePerGas.from(5_000_000_000);

    const x_gas_price = GasPrice.from(0);
    const y_gas_price = GasPrice.from(0);

    try std.testing.expectEqual(
        @as(i32, 1),
        compare_fee_market_priority(
            x_gas_price,
            x_max_fee,
            x_max_priority,
            y_gas_price,
            y_max_fee,
            y_max_priority,
            base_fee,
            true,
        ),
    );
}

test "compare_fee_market_priority — EIP-1559 caps priority by max fee minus base fee" {
    const base_fee = BaseFeePerGas.from(25_000_000_000);

    const x_max_fee = MaxFeePerGas.from(27_000_000_000);
    const x_max_priority = MaxPriorityFeePerGas.from(5_000_000_000);

    const y_max_fee = MaxFeePerGas.from(28_000_000_000);
    const y_max_priority = MaxPriorityFeePerGas.from(1_000_000_000);

    const x_gas_price = GasPrice.from(0);
    const y_gas_price = GasPrice.from(0);

    try std.testing.expectEqual(
        @as(i32, -1),
        compare_fee_market_priority(
            x_gas_price,
            x_max_fee,
            x_max_priority,
            y_gas_price,
            y_max_fee,
            y_max_priority,
            base_fee,
            true,
        ),
    );
}

test "compare_fee_market_priority — EIP-1559 max fee below base fee uses max fee" {
    const base_fee = BaseFeePerGas.from(30_000_000_000);

    const x_max_fee = MaxFeePerGas.from(25_000_000_000);
    const x_max_priority = MaxPriorityFeePerGas.from(2_000_000_000);

    const y_max_fee = MaxFeePerGas.from(28_000_000_000);
    const y_max_priority = MaxPriorityFeePerGas.from(1_000_000_000);

    const x_gas_price = GasPrice.from(0);
    const y_gas_price = GasPrice.from(0);

    try std.testing.expectEqual(
        @as(i32, 1),
        compare_fee_market_priority(
            x_gas_price,
            x_max_fee,
            x_max_priority,
            y_gas_price,
            y_max_fee,
            y_max_priority,
            base_fee,
            true,
        ),
    );
}

test "compare_fee_market_priority — legacy compares gas price descending" {
    const base_fee = BaseFeePerGas.from(0);

    const x_gas_price = GasPrice.from(30_000_000_000);
    const y_gas_price = GasPrice.from(20_000_000_000);

    const x_max_fee = MaxFeePerGas.from(0);
    const x_max_priority = MaxPriorityFeePerGas.from(0);
    const y_max_fee = MaxFeePerGas.from(0);
    const y_max_priority = MaxPriorityFeePerGas.from(0);

    try std.testing.expectEqual(
        @as(i32, -1),
        compare_fee_market_priority(
            x_gas_price,
            x_max_fee,
            x_max_priority,
            y_gas_price,
            y_max_fee,
            y_max_priority,
            base_fee,
            false,
        ),
    );
}

test "compare_fee_market_priority — equality returns zero" {
    const base_fee = BaseFeePerGas.from(10_000_000_000);

    const gas_price = GasPrice.from(20_000_000_000);
    const max_fee = MaxFeePerGas.from(20_000_000_000);
    const max_priority = MaxPriorityFeePerGas.from(5_000_000_000);

    try std.testing.expectEqual(
        @as(i32, 0),
        compare_fee_market_priority(
            gas_price,
            max_fee,
            max_priority,
            gas_price,
            max_fee,
            max_priority,
            base_fee,
            true,
        ),
    );
}

test "effective_gas_price clamps to max fee when base fee is larger" {
    const fee = ResolvedFeeTuple{
        .max_fee = MaxFeePerGas.from(2),
        .max_priority = MaxPriorityFeePerGas.from(2),
    };
    try std.testing.expect(effective_gas_price(U256.MAX, fee).eq(U256.from_u64(2)));
}
