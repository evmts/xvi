/// JSON-RPC server configuration.
///
/// Mirrors core settings from Nethermind's JsonRpcConfig needed for
/// HTTP and WebSocket transports.
const std = @import("std");
const errors = @import("error.zig");
const scan = @import("scan.zig");

const default_enabled = false;
const default_host: []const u8 = "127.0.0.1";
const default_port: u16 = 8545;
const default_websocket_port: ?u16 = null;
const default_ipc_unix_domain_socket_path: ?[]const u8 = null;
const default_timeout_ms: u32 = 20_000;
const default_request_queue_limit: usize = 500;
const default_max_batch_size: usize = 1024;
const default_max_request_body_size: ?usize = 30_000_000;
const default_max_batch_response_body_size: ?usize = 33_554_432;
const default_strict_hex_format = true;

/// JSON-RPC server configuration options, aligned with Nethermind defaults.
pub const RpcServerConfig = struct {
    /// Enable the JSON-RPC server.
    enabled: bool = default_enabled,
    /// Interface to bind (IPv4/IPv6 literal or hostname).
    host: []const u8 = default_host,
    /// HTTP JSON-RPC port.
    port: u16 = default_port,
    /// Optional WebSocket port override (defaults to HTTP port when null).
    websocket_port: ?u16 = default_websocket_port,
    /// Optional UNIX domain socket path for IPC transport.
    ipc_unix_domain_socket_path: ?[]const u8 = default_ipc_unix_domain_socket_path,
    /// Per-request timeout in milliseconds.
    timeout_ms: u32 = default_timeout_ms,
    /// Maximum number of queued requests.
    request_queue_limit: usize = default_request_queue_limit,
    /// Maximum JSON-RPC batch size.
    max_batch_size: usize = default_max_batch_size,
    /// Maximum request body size in bytes (null to disable the limit).
    max_request_body_size: ?usize = default_max_request_body_size,
    /// Maximum batch response body size in bytes (null to disable the limit).
    max_batch_response_body_size: ?usize = default_max_batch_response_body_size,
    /// Enforce strict hex encoding (EIP-1474 Quantity/Data rules).
    strict_hex_format: bool = default_strict_hex_format,

    /// Returns the WebSocket port, defaulting to the HTTP port when unset.
    pub fn effective_websocket_port(self: RpcServerConfig) u16 {
        return self.websocket_port orelse self.port;
    }
};

/// Validate the top-level `jsonrpc` version in a request object.
///
/// Returns `null` when the version is exactly `"2.0"`, otherwise returns
/// an EIP-1474-compatible error code.
pub fn validate_request_jsonrpc_version(request: []const u8) ?errors.JsonRpcErrorCode {
    const fields = scan.scan_request_fields(request) catch |err| return scan.scan_error_to_jsonrpc_error(err);
    return scan.validate_jsonrpc_version_token(request, fields);
}

/// Validate JSON-RPC batch size against server configuration.
///
/// Mirrors Nethermind behavior: unauthenticated requests are limited by
/// `max_batch_size`; authenticated contexts bypass this check.
///
/// Returns `null` when accepted, otherwise `.limit_exceeded`.
pub fn validate_batch_size(config: RpcServerConfig, batch_size: usize, is_authenticated: bool) ?errors.JsonRpcErrorCode {
    if (is_authenticated) return null;
    if (batch_size > config.max_batch_size) return .limit_exceeded;
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "rpc server config defaults websocket port to http port" {
    const cfg = RpcServerConfig{};
    try std.testing.expectEqual(default_port, cfg.effective_websocket_port());
}

test "rpc server config respects websocket port override" {
    const cfg = RpcServerConfig{ .websocket_port = 9546 };
    try std.testing.expectEqual(@as(u16, 9546), cfg.effective_websocket_port());
}

test "rpc server config defaults match Nethermind core settings" {
    const cfg = RpcServerConfig{};
    try std.testing.expectEqual(default_enabled, cfg.enabled);
    try std.testing.expectEqualStrings(default_host, cfg.host);
    try std.testing.expectEqual(default_port, cfg.port);
    try std.testing.expectEqual(default_websocket_port, cfg.websocket_port);
}

test "rpc server config defaults ipc socket path to null" {
    const cfg = RpcServerConfig{};
    try std.testing.expectEqual(default_ipc_unix_domain_socket_path, cfg.ipc_unix_domain_socket_path);
}

test "rpc server config defaults match Nethermind limits" {
    const cfg = RpcServerConfig{};
    try std.testing.expectEqual(default_timeout_ms, cfg.timeout_ms);
    try std.testing.expectEqual(default_request_queue_limit, cfg.request_queue_limit);
    try std.testing.expectEqual(default_max_batch_size, cfg.max_batch_size);
    try std.testing.expectEqual(default_max_request_body_size, cfg.max_request_body_size);
    try std.testing.expectEqual(default_max_batch_response_body_size, cfg.max_batch_response_body_size);
    try std.testing.expectEqual(default_strict_hex_format, cfg.strict_hex_format);
}

test "validate_request_jsonrpc_version accepts 2.0 request objects" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expect(validate_request_jsonrpc_version(req) == null);
}

test "validate_request_jsonrpc_version rejects missing jsonrpc field" {
    const req =
        "{\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expectEqual(errors.JsonRpcErrorCode.invalid_request, validate_request_jsonrpc_version(req).?);
}

test "validate_request_jsonrpc_version rejects unsupported version" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"1.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expectEqual(errors.JsonRpcErrorCode.jsonrpc_version_not_supported, validate_request_jsonrpc_version(req).?);
}

test "validate_request_jsonrpc_version rejects non-string version token" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": 2.0,\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expectEqual(errors.JsonRpcErrorCode.invalid_request, validate_request_jsonrpc_version(req).?);
}

test "validate_request_jsonrpc_version returns parse_error on unterminated version string" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0,\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expectEqual(errors.JsonRpcErrorCode.parse_error, validate_request_jsonrpc_version(req).?);
}

test "validate_batch_size accepts batches at configured limit" {
    const cfg = RpcServerConfig{ .max_batch_size = 4 };
    try std.testing.expect(validate_batch_size(cfg, 4, false) == null);
}

test "validate_batch_size rejects oversized unauthenticated batches" {
    const cfg = RpcServerConfig{ .max_batch_size = 4 };
    try std.testing.expectEqual(errors.JsonRpcErrorCode.limit_exceeded, validate_batch_size(cfg, 5, false).?);
}

test "validate_batch_size allows oversized authenticated batches" {
    const cfg = RpcServerConfig{ .max_batch_size = 4 };
    try std.testing.expect(validate_batch_size(cfg, 10, true) == null);
}
