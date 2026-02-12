//! JSON-RPC server module for the Guillotine execution client.
const std = @import("std");

const server = @import("server.zig");
const errors = @import("error.zig");
const envelope = @import("envelope.zig");
const response = @import("response.zig");
const eth = @import("eth.zig");
const dispatch = @import("dispatch.zig");

/// JSON-RPC server configuration.
pub const RpcServerConfig = server.RpcServerConfig;
/// Top-level JSON-RPC version validator.
pub const validate_request_jsonrpc_version = server.validate_request_jsonrpc_version;
/// JSON-RPC error codes per EIP-1474 and Nethermind extensions.
pub const JsonRpcErrorCode = errors.JsonRpcErrorCode;
/// JSON-RPC envelope utilities (ID extraction, zero-copy)
pub const Envelope = envelope;
/// JSON-RPC response serializers
pub const Response = response.Response;
/// ETH namespace API surface (comptime DI)
pub const EthApi = eth.EthApi;
/// Namespace resolver for top-level JSON-RPC method names.
pub const resolve_namespace = dispatch.resolve_namespace;
/// Single-pass request parser for namespace routing.
pub const parse_request_namespace = dispatch.parse_request_namespace;
/// Namespace parser result type.
pub const ParseNamespaceResult = dispatch.ParseNamespaceResult;

test {
    std.testing.refAllDecls(@This());
}
