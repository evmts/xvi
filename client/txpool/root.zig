/// TxPool module root: re-exports public surface for tests and consumers.
///
/// Public API surface is intentionally minimal and documented.
const std = @import("std");

const pool = @import("pool.zig");
const accept_result = @import("accept_result.zig");
const handling_options = @import("handling_options.zig");
const sorter = @import("sorter.zig");
const limits = @import("limits.zig");
const policy = @import("policy.zig");
const admission = @import("admission.zig");

/// Transaction pool interface (vtable-based). Mirrors Nethermind's ITxPool minimal surface.
/// Consumers should depend on this alias, not on `pool.zig` internals.
pub const TxPool = pool.TxPool;
/// Transaction pool configuration (defaults align with Nethermind).
pub const TxPoolConfig = pool.TxPoolConfig;
/// Transaction admission outcome model (Nethermind parity).
pub const AcceptTxResult = accept_result.AcceptTxResult;
/// Transaction submission handling flags (Nethermind TxHandlingOptions parity).
pub const TxHandlingOptions = handling_options.TxHandlingOptions;
/// Fee market comparator (EIP-1559-aware).
pub const compare_fee_market_priority = sorter.compare_fee_market_priority;
/// Broadcast policy helper: base-fee threshold calculator (parity with Nethermind's TxBroadcaster.CalculateBaseFeeThreshold).
pub const calculate_base_fee_threshold = policy.calculate_base_fee_threshold;
/// Broadcast policy helper: persistent broadcast quota per block (parity with Nethermind's TxBroadcaster persistent quota logic).
pub const calculate_persistent_broadcast_quota = policy.calculate_persistent_broadcast_quota;

/// Admission helpers: re-export to avoid wrapper signature drift and keep
/// a single public import location for txpool checks.
pub const fits_size_limits = limits.fits_size_limits;
/// Admission helper: enforces optional transaction gas limit cap.
pub const fits_gas_limit = limits.fits_gas_limit;
/// Admission helper: enforces blob tip and blob base-fee constraints.
pub const enforce_min_priority_fee_for_blobs = limits.enforce_min_priority_fee_for_blobs;
/// Admission helper: rejects nonces that exceed in-order sender window.
pub const enforce_nonce_gap = limits.enforce_nonce_gap;
/// Admission helper: duplicate precheck against hash cache + typed pools.
pub const precheck_duplicate = admission.precheck_duplicate;

test {
    std.testing.refAllDecls(@This());
}
