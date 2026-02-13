//! Lightweight JSON-RPC method resolver using Voltaire enums.
//!
//! Purpose: map a JSON-RPC `method` string to its namespace (engine/eth/debug)
//! without allocating or constructing full request payloads. Mirrors the
//! initial routing step in Nethermind's JsonRpcProcessor.

const std = @import("std");
const jsonrpc = @import("jsonrpc");
const errors = @import("error.zig");
const scan = @import("scan.zig");

fn is_engine_versioned_method_name(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "engine_")) return false;
    if (name.len < 2) return false;

    var i: usize = name.len;
    while (i > 0 and std.ascii.isDigit(name[i - 1])) : (i -= 1) {}
    if (i == name.len or i == 0) return false;
    return name[i - 1] == 'V';
}

fn resolve_known_method_namespace(
    comptime MethodUnion: type,
    method_name: []const u8,
    namespace: std.meta.Tag(jsonrpc.JsonRpcMethod),
) ?std.meta.Tag(jsonrpc.JsonRpcMethod) {
    if (MethodUnion.fromMethodName(method_name)) |_| {
        return namespace;
    } else |err| switch (err) {
        error.UnknownMethod => return null,
        else => return null,
    }
}

/// Returns the root namespace tag of a JSON-RPC method name.
/// - `.engine` for Engine API
/// - `.eth` for Ethereum API
/// - `.debug` for Debug API
/// - `null` if the method is unknown to all namespaces
fn resolve_namespace(method_name: []const u8) ?std.meta.Tag(jsonrpc.JsonRpcMethod) {
    // Fast prefix short-circuit: only probe the relevant namespace
    if (std.mem.startsWith(u8, method_name, "eth_")) {
        return resolve_known_method_namespace(jsonrpc.eth.EthMethod, method_name, .eth);
    }

    if (std.mem.startsWith(u8, method_name, "engine_")) {
        if (resolve_known_method_namespace(jsonrpc.engine.EngineMethod, method_name, .engine)) |tag| {
            return tag;
        }
        // Keep routing versioned engine_* methods to the Engine namespace
        // even if the current Voltaire method registry is behind
        // execution-apis additions.
        if (is_engine_versioned_method_name(method_name)) return .engine;
        return null;
    }

    if (std.mem.startsWith(u8, method_name, "debug_")) {
        return resolve_known_method_namespace(jsonrpc.debug.DebugMethod, method_name, .debug);
    }

    return null;
}

test "resolve_namespace returns .eth for eth_*" {
    const tag = resolve_namespace("eth_blockNumber");
    try std.testing.expect(tag != null);
    try std.testing.expectEqual(std.meta.Tag(jsonrpc.JsonRpcMethod).eth, tag.?);
}

test "resolve_namespace returns .engine for engine_*" {
    const tag = resolve_namespace("engine_getPayloadV3");
    try std.testing.expect(tag != null);
    try std.testing.expectEqual(std.meta.Tag(jsonrpc.JsonRpcMethod).engine, tag.?);
}

test "resolve_namespace treats engine_getClientVersionV1 as engine" {
    const tag = resolve_namespace("engine_getClientVersionV1");
    try std.testing.expect(tag != null);
    try std.testing.expectEqual(std.meta.Tag(jsonrpc.JsonRpcMethod).engine, tag.?);
}

test "resolve_namespace returns null for unknown" {
    try std.testing.expect(resolve_namespace("unknown_method") == null);
}

/// Minimal JSON-RPC request parser that extracts the `method` string and
/// resolves it to a root namespace tag. Returns an EIP-1474 error code for
/// unknown methods without allocating or fully parsing the JSON.
const ParseNamespaceResult = union(enum) {
    namespace: std.meta.Tag(jsonrpc.JsonRpcMethod),
    err: errors.JsonRpcErrorCode,
};

/// Extracts the `method` field from a JSON-RPC request and returns its
/// resolved namespace tag. If the method is unknown, returns
/// `.error(.method_not_found)`. If the field is missing or malformed,
/// returns `.error(.invalid_request)` per EIP-1474.
fn parse_request_namespace(request: []const u8) ParseNamespaceResult {
    const fields = switch (scan.scan_and_validate_request_fields(request)) {
        .fields => |value| value,
        .err => |code| return .{ .err = code },
    };

    return parse_request_namespace_from_fields(request, fields);
}

/// Resolve request namespace from previously scanned request field spans.
///
/// This avoids reparsing the JSON payload when `scan_and_validate_request_fields`
/// already ran in an upstream dispatch stage.
pub fn parse_request_namespace_from_fields(request: []const u8, fields: scan.RequestFieldSpans) ParseNamespaceResult {
    const method_span = fields.method orelse return .{ .err = errors.code.invalid_request };
    const method_token = request[method_span.start..method_span.end];
    if (method_token.len < 2 or method_token[0] != '"' or method_token[method_token.len - 1] != '"') {
        return .{ .err = errors.code.invalid_request };
    }
    const method_name = method_token[1 .. method_token.len - 1];

    if (resolve_namespace(method_name)) |tag| {
        return .{ .namespace = tag };
    } else {
        return .{ .err = errors.code.method_not_found };
    }
}

// ============================================================================
// Additional tests for debug_* mapping and batch input handling
// ============================================================================

test "resolve_namespace returns .debug for debug_*" {
    const tag = resolve_namespace("debug_getRawBlock");
    try std.testing.expect(tag != null);
    try std.testing.expectEqual(std.meta.Tag(jsonrpc.JsonRpcMethod).debug, tag.?);
}

test "parse_request_namespace returns invalid_request for batch array input" {
    const req =
        "[\n" ++
        "  {\n" ++
        "    \"jsonrpc\": \"2.0\",\n" ++
        "    \"id\": 1,\n" ++
        "    \"method\": \"eth_blockNumber\",\n" ++
        "    \"params\": []\n" ++
        "  }\n" ++
        "]";

    const res = parse_request_namespace(req);
    switch (res) {
        .namespace => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.invalid_request, code),
    }
}

test "parse_request_namespace returns namespace tag for known eth method" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_blockNumber\",\n" ++
        "  \"params\": []\n" ++
        "}";

    const res = parse_request_namespace(req);
    switch (res) {
        .namespace => |tag| {
            try std.testing.expectEqual(std.meta.Tag(jsonrpc.JsonRpcMethod).eth, tag);
        },
        .err => |_| return error.UnexpectedError,
    }
}

test "parse_request_namespace returns method_not_found for unknown method" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"foo_bar\",\n" ++
        "  \"params\": []\n" ++
        "}";

    const res = parse_request_namespace(req);
    switch (res) {
        .namespace => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.method_not_found, code),
    }
}

test "parse_request_namespace returns invalid_request when method missing" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"params\": []\n" ++
        "}";

    const res = parse_request_namespace(req);
    switch (res) {
        .namespace => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.invalid_request, code),
    }
}

test "parse_request_namespace validates jsonrpc version before method resolution" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"1.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"foo_bar\",\n" ++
        "  \"params\": []\n" ++
        "}";

    const res = parse_request_namespace(req);
    switch (res) {
        .namespace => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.jsonrpc_version_not_supported, code),
    }
}

test "parse_request_namespace validates jsonrpc field before method handling" {
    const req =
        "{\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_blockNumber\",\n" ++
        "  \"params\": []\n" ++
        "}";

    const res = parse_request_namespace(req);
    switch (res) {
        .namespace => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.invalid_request, code),
    }
}

test "parse_request_namespace rejects malformed JSON after method extraction" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"method\": \"eth_blockNumber\",\n" ++
        "  \"params\": []\n";

    const res = parse_request_namespace(req);
    switch (res) {
        .namespace => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.parse_error, code),
    }
}

test "parse_request_namespace rejects trailing non-json bytes" {
    const req = "{ \"jsonrpc\": \"2.0\", \"method\": \"eth_blockNumber\", \"params\": [] } trailing";

    const res = parse_request_namespace(req);
    switch (res) {
        .namespace => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.parse_error, code),
    }
}

test "parse_request_namespace_from_fields resolves namespace without rescanning request" {
    const req = "{ \"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"eth_blockNumber\", \"params\": [] }";
    const fields = switch (scan.scan_and_validate_request_fields(req)) {
        .fields => |value| value,
        .err => |_| return error.UnexpectedError,
    };
    const res = parse_request_namespace_from_fields(req, fields);
    switch (res) {
        .namespace => |tag| try std.testing.expectEqual(std.meta.Tag(jsonrpc.JsonRpcMethod).eth, tag),
        .err => |_| return error.UnexpectedError,
    }
}
