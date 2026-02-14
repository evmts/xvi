//! JSON-RPC server module for the Guillotine execution client.
const std = @import("std");

const server = @import("server.zig");
const errors = @import("error.zig");
const response = @import("response.zig");
const eth = @import("eth.zig");
const net = @import("net.zig");
const web3 = @import("web3.zig");

/// JSON-RPC server configuration.
pub const RpcServerConfig = server.RpcServerConfig;
/// Top-level JSON-RPC version validator.
pub const validate_request_jsonrpc_version = server.validate_request_jsonrpc_version;
/// Single-request JSON-RPC executor (comptime DI).
pub const SingleRequestProcessor = server.SingleRequestProcessor;
/// JSON-RPC error codes per EIP-1474 and Nethermind extensions.
pub const JsonRpcErrorCode = errors.JsonRpcErrorCode;
/// JSON-RPC response serializers
pub const Response = response.Response;
/// ETH namespace API surface (comptime DI)
pub const EthApi = eth.EthApi;
/// NET namespace API surface (comptime DI)
pub const NetApi = net.NetApi;
/// WEB3 namespace API surface (comptime DI)
pub const Web3Api = web3.Web3Api;

test {
    std.testing.refAllDecls(@This());
}
