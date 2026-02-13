const std = @import("std");
const primitives = @import("primitives");

/// JSON-RPC error code primitive (Voltaire Int32).
pub const JsonRpcErrorCode = primitives.Int32.Int32;

/// JSON-RPC / Nethermind-compatible error code constants.
///
/// Using primitive-backed constants avoids introducing a local enum type while
/// keeping the codes centralized and shared across the RPC module.
pub const code = struct {
    // EIP-1474 Standard Errors
    pub const parse_error: JsonRpcErrorCode = -32700;
    pub const invalid_request: JsonRpcErrorCode = -32600;
    pub const method_not_found: JsonRpcErrorCode = -32601;
    pub const invalid_params: JsonRpcErrorCode = -32602;
    pub const internal_error: JsonRpcErrorCode = -32603;
    pub const invalid_input: JsonRpcErrorCode = -32000;
    pub const resource_not_found: JsonRpcErrorCode = -32001;
    pub const resource_unavailable: JsonRpcErrorCode = -32002;
    pub const transaction_rejected: JsonRpcErrorCode = -32003;
    pub const method_not_supported: JsonRpcErrorCode = -32004;
    pub const limit_exceeded: JsonRpcErrorCode = -32005;
    pub const jsonrpc_version_not_supported: JsonRpcErrorCode = -32006;

    // Nethermind Extensions (used in downstream tooling/tests)
    pub const execution_reverted: JsonRpcErrorCode = 3;
    pub const tx_sync_timeout: JsonRpcErrorCode = 4;
    pub const transaction_rejected_nethermind: JsonRpcErrorCode = -32010;
    pub const execution_error: JsonRpcErrorCode = -32015;
    pub const timeout: JsonRpcErrorCode = -32016;
    pub const module_timeout: JsonRpcErrorCode = -32017;
    pub const account_locked: JsonRpcErrorCode = -32020;
    pub const unknown_block: JsonRpcErrorCode = -39001;
    pub const nonce_too_low: JsonRpcErrorCode = -38010;
    pub const nonce_too_high: JsonRpcErrorCode = -38011;
    pub const insufficient_intrinsic_gas: JsonRpcErrorCode = -38013;
    pub const invalid_transaction: JsonRpcErrorCode = -38014;
    pub const block_gas_limit_reached: JsonRpcErrorCode = -38015;
    pub const invalid_input_blocks_out_of_order: JsonRpcErrorCode = -38020;
    pub const block_timestamp_not_increased: JsonRpcErrorCode = -38021;
    pub const sender_is_not_eoa: JsonRpcErrorCode = -38024;
    pub const max_init_code_size_exceeded: JsonRpcErrorCode = -38025;
    pub const invalid_input_too_many_blocks: JsonRpcErrorCode = -38026;
    pub const pruned_history_unavailable: JsonRpcErrorCode = 4444;
};

/// Returns the default, human-readable message for a given error code.
pub fn default_message(err_code: JsonRpcErrorCode) []const u8 {
    return switch (err_code) {
        code.parse_error => "Parse error",
        code.invalid_request => "Invalid request",
        code.method_not_found => "Method not found",
        code.invalid_params => "Invalid params",
        code.internal_error => "Internal error",
        code.invalid_input => "Invalid input",
        code.resource_not_found => "Resource not found",
        code.resource_unavailable => "Resource unavailable",
        code.transaction_rejected, code.transaction_rejected_nethermind => "Transaction rejected",
        code.method_not_supported => "Method not supported",
        code.limit_exceeded => "Limit exceeded",
        code.jsonrpc_version_not_supported => "JSON-RPC version not supported",
        code.execution_reverted => "Execution reverted",
        code.timeout, code.module_timeout => "Timeout",
        code.account_locked => "Account locked",
        else => "Internal error",
    };
}

// Aliases / Legacy mappings (Nethermind compatibility)
pub const Legacy = struct {
    pub const resource_not_found_legacy: JsonRpcErrorCode = code.invalid_input;
    pub const default: JsonRpcErrorCode = code.invalid_input;
    pub const reverted_simulate: JsonRpcErrorCode = code.invalid_input;
    pub const vm_error: JsonRpcErrorCode = code.execution_error;
    pub const intrinsic_gas: JsonRpcErrorCode = code.insufficient_intrinsic_gas;
    pub const insufficient_funds: JsonRpcErrorCode = code.invalid_transaction;
    pub const block_number_invalid: JsonRpcErrorCode = code.invalid_input_blocks_out_of_order;
    pub const block_timestamp_invalid: JsonRpcErrorCode = code.block_timestamp_not_increased;
    pub const client_limit_exceeded_error: JsonRpcErrorCode = code.invalid_input_too_many_blocks;
    pub const client_limit_exceeded: JsonRpcErrorCode = code.invalid_input_too_many_blocks;
};

// ============================================================================
// Tests
// ============================================================================

test "jsonrpc error codes match eip-1474" {
    try std.testing.expectEqual(@as(i32, -32700), code.parse_error);
    try std.testing.expectEqual(@as(i32, -32600), code.invalid_request);
    try std.testing.expectEqual(@as(i32, -32601), code.method_not_found);
    try std.testing.expectEqual(@as(i32, -32602), code.invalid_params);
    try std.testing.expectEqual(@as(i32, -32603), code.internal_error);
    try std.testing.expectEqual(@as(i32, -32000), code.invalid_input);
    try std.testing.expectEqual(@as(i32, -32001), code.resource_not_found);
    try std.testing.expectEqual(@as(i32, -32002), code.resource_unavailable);
    try std.testing.expectEqual(@as(i32, -32003), code.transaction_rejected);
    try std.testing.expectEqual(@as(i32, -32004), code.method_not_supported);
    try std.testing.expectEqual(@as(i32, -32005), code.limit_exceeded);
    try std.testing.expectEqual(@as(i32, -32006), code.jsonrpc_version_not_supported);
}

test "jsonrpc error default messages follow eip-1474" {
    try std.testing.expectEqualStrings("Parse error", default_message(code.parse_error));
    try std.testing.expectEqualStrings("Invalid request", default_message(code.invalid_request));
    try std.testing.expectEqualStrings("Method not found", default_message(code.method_not_found));
    try std.testing.expectEqualStrings("Invalid params", default_message(code.invalid_params));
    try std.testing.expectEqualStrings("Internal error", default_message(code.internal_error));
    try std.testing.expectEqualStrings("Invalid input", default_message(code.invalid_input));
    try std.testing.expectEqualStrings("Resource not found", default_message(code.resource_not_found));
    try std.testing.expectEqualStrings("Resource unavailable", default_message(code.resource_unavailable));
    try std.testing.expectEqualStrings("Transaction rejected", default_message(code.transaction_rejected));
    try std.testing.expectEqualStrings("Method not supported", default_message(code.method_not_supported));
    try std.testing.expectEqualStrings("Limit exceeded", default_message(code.limit_exceeded));
    try std.testing.expectEqualStrings("JSON-RPC version not supported", default_message(code.jsonrpc_version_not_supported));
}

test "jsonrpc error codes include nethermind extensions" {
    try std.testing.expectEqual(@as(i32, 3), code.execution_reverted);
    try std.testing.expectEqual(@as(i32, 4), code.tx_sync_timeout);
    try std.testing.expectEqual(@as(i32, -32010), code.transaction_rejected_nethermind);
    try std.testing.expectEqual(@as(i32, -32015), code.execution_error);
    try std.testing.expectEqual(@as(i32, -32016), code.timeout);
    try std.testing.expectEqual(@as(i32, -32017), code.module_timeout);
    try std.testing.expectEqual(@as(i32, -32020), code.account_locked);
    try std.testing.expectEqual(@as(i32, -39001), code.unknown_block);
    try std.testing.expectEqual(@as(i32, -38010), code.nonce_too_low);
    try std.testing.expectEqual(@as(i32, -38011), code.nonce_too_high);
    try std.testing.expectEqual(@as(i32, -38013), code.insufficient_intrinsic_gas);
    try std.testing.expectEqual(@as(i32, -38014), code.invalid_transaction);
    try std.testing.expectEqual(@as(i32, -38015), code.block_gas_limit_reached);
    try std.testing.expectEqual(@as(i32, -38020), code.invalid_input_blocks_out_of_order);
    try std.testing.expectEqual(@as(i32, -38021), code.block_timestamp_not_increased);
    try std.testing.expectEqual(@as(i32, -38024), code.sender_is_not_eoa);
    try std.testing.expectEqual(@as(i32, -38025), code.max_init_code_size_exceeded);
    try std.testing.expectEqual(@as(i32, -38026), code.invalid_input_too_many_blocks);
    try std.testing.expectEqual(@as(i32, 4444), code.pruned_history_unavailable);

    try std.testing.expectEqual(@as(i32, -32000), Legacy.resource_not_found_legacy);
    try std.testing.expectEqual(@as(i32, -32000), Legacy.default);
    try std.testing.expectEqual(@as(i32, -32000), Legacy.reverted_simulate);
    try std.testing.expectEqual(@as(i32, -32015), Legacy.vm_error);
    try std.testing.expectEqual(@as(i32, -38013), Legacy.intrinsic_gas);
    try std.testing.expectEqual(@as(i32, -38014), Legacy.insufficient_funds);
    try std.testing.expectEqual(@as(i32, -38020), Legacy.block_number_invalid);
    try std.testing.expectEqual(@as(i32, -38021), Legacy.block_timestamp_invalid);
    try std.testing.expectEqual(@as(i32, -38026), Legacy.client_limit_exceeded_error);
    try std.testing.expectEqual(@as(i32, -38026), Legacy.client_limit_exceeded);
}

test "jsonrpc error default messages include nethermind extensions" {
    try std.testing.expectEqualStrings("Execution reverted", default_message(code.execution_reverted));
    try std.testing.expectEqualStrings("Timeout", default_message(code.timeout));
    try std.testing.expectEqualStrings("Account locked", default_message(code.account_locked));
}
