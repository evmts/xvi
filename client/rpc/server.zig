/// JSON-RPC server configuration.
///
/// Mirrors core settings from Nethermind's JsonRpcConfig needed for
/// HTTP and WebSocket transports.
const std = @import("std");
const jsonrpc = @import("jsonrpc");
const errors = @import("error.zig");
const envelope = @import("envelope.zig");
const EthApi = @import("eth.zig").EthApi;
const NetApi = @import("net.zig").NetApi;
const Response = @import("response.zig").Response;
const scan = @import("scan.zig");
const Web3Api = @import("web3.zig").Web3Api;

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
    return switch (scan.scan_and_validate_request_fields(request)) {
        .fields => null,
        .err => |code| code,
    };
}

/// Single-request JSON-RPC executor using comptime-injected namespace backends.
///
/// Supports the current atomic method set:
/// - `eth_chainId`
/// - `net_version`
/// - `web3_clientVersion`
/// - `web3_sha3`
pub fn SingleRequestProcessor(comptime EthProvider: type, comptime NetProvider: type, comptime Web3Provider: type) type {
    return struct {
        const Self = @This();

        eth_api: EthApi(EthProvider),
        net_api: NetApi(NetProvider),
        web3_api: Web3Api(Web3Provider),

        /// Construct a processor from concrete namespace providers.
        pub fn init(
            eth_provider: *const EthProvider,
            net_provider: *const NetProvider,
            web3_provider: *const Web3Provider,
        ) Self {
            return .{
                .eth_api = .{ .provider = eth_provider },
                .net_api = .{ .provider = net_provider },
                .web3_api = .{ .provider = web3_provider },
            };
        }

        /// Execute one JSON-RPC request object and write the response, if any.
        pub fn handle(self: *const Self, writer: anytype, request: []const u8) !void {
            const parsed = switch (parse_single_request_for_dispatch(request)) {
                .request => |value| value,
                .err => |code| {
                    try Response.write_error(writer, .null, code, errors.default_message(code), null);
                    return;
                },
            };

            try self.handle_parsed(writer, request, parsed);
        }

        /// Execute one JSON-RPC request with pre-parsed routing metadata.
        pub fn handle_parsed(self: *const Self, writer: anytype, request: []const u8, parsed: ParsedSingleRequest) !void {
            switch (parsed.method) {
                .eth_chainId => try self.eth_api.handle_chain_id(writer, parsed.id),
                .net_version => try self.net_api.handle_version(writer, parsed.id),
                .web3_clientVersion => try self.web3_api.handle_client_version(writer, parsed.id),
                .web3_sha3 => try self.web3_api.handle_sha3_from_request_with_id(writer, parsed.id, request),
                .unknown => switch (parsed.id) {
                    .missing => return,
                    .present => |id| {
                        const code = errors.code.method_not_found;
                        try Response.write_error(writer, id, code, errors.default_message(code), null);
                    },
                },
            }
        }
    };
}

/// Batch-request JSON-RPC executor using comptime-injected namespace backends.
///
/// Reuses `SingleRequestProcessor` for each top-level batch entry and emits a
/// JSON-RPC batch response array containing only entries that produced output
/// (notifications are omitted).
pub fn BatchRequestExecutor(comptime EthProvider: type, comptime NetProvider: type, comptime Web3Provider: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: RpcServerConfig,
        single_processor: SingleRequestProcessor(EthProvider, NetProvider, Web3Provider),

        /// Construct a batch executor from concrete namespace providers.
        pub fn init(
            allocator: std.mem.Allocator,
            config: RpcServerConfig,
            eth_provider: *const EthProvider,
            net_provider: *const NetProvider,
            web3_provider: *const Web3Provider,
        ) Self {
            return .{
                .allocator = allocator,
                .config = config,
                .single_processor = SingleRequestProcessor(EthProvider, NetProvider, Web3Provider).init(
                    eth_provider,
                    net_provider,
                    web3_provider,
                ),
            };
        }

        /// Execute one JSON-RPC batch request array and write response(s), if any.
        pub fn handle(self: *const Self, writer: anytype, request: []const u8, is_authenticated: bool) !void {
            const batch_count = switch (parse_request_kind_for_dispatch(self.config, request, is_authenticated)) {
                .request => |kind| switch (kind) {
                    .batch => |count| count,
                    .object => {
                        try write_null_id_error(writer, errors.code.invalid_request);
                        return;
                    },
                },
                .err => |code| {
                    try write_null_id_error(writer, code);
                    return;
                },
            };
            _ = batch_count;

            var index = batch_array_open_index(request) orelse {
                try write_null_id_error(writer, errors.code.parse_error);
                return;
            };
            index += 1; // past '['

            var entry_buf = std.array_list.Managed(u8).init(self.allocator);
            defer entry_buf.deinit();

            const max_batch_response_body_size = if (is_authenticated) null else self.config.max_batch_response_body_size;
            var response_size: usize = 0;
            var emitted: usize = 0;
            while (true) {
                skip_ascii_whitespace(request, &index);
                if (index >= request.len) {
                    try write_null_id_error(writer, errors.code.parse_error);
                    return;
                }
                if (request[index] == ']') break;

                const entry_start = index;
                const entry_end = scan_batch_entry_end(request, index) catch {
                    try write_null_id_error(writer, errors.code.parse_error);
                    return;
                };

                entry_buf.clearRetainingCapacity();
                const entry_request = request[entry_start..entry_end];
                switch (parse_single_request_for_dispatch(entry_request)) {
                    .request => |parsed| try self.single_processor.handle_parsed(entry_buf.writer(), entry_request, parsed),
                    .err => |code| try write_null_id_error(entry_buf.writer(), code),
                }

                if (entry_buf.items.len != 0) {
                    if (emitted == 0) {
                        try writer.writeByte('[');
                        response_size += 1;
                    } else {
                        try writer.writeByte(',');
                        response_size += 1;
                    }
                    try writer.writeAll(entry_buf.items);
                    response_size += entry_buf.items.len;
                    emitted += 1;

                    if (max_batch_response_body_size) |limit| {
                        // Match Nethermind batch serialization behavior:
                        // once current response size exceeds the configured cap,
                        // stop producing further batch entries.
                        if (response_size > limit) break;
                    }
                }

                index = entry_end;
                skip_ascii_whitespace(request, &index);
                if (index >= request.len) {
                    try write_null_id_error(writer, errors.code.parse_error);
                    return;
                }
                switch (request[index]) {
                    ',' => index += 1,
                    ']' => break,
                    else => {
                        try write_null_id_error(writer, errors.code.parse_error);
                        return;
                    },
                }
            }

            if (emitted != 0) {
                try writer.writeByte(']');
            }
        }

        fn write_null_id_error(writer: anytype, code: errors.JsonRpcErrorCode) !void {
            try Response.write_error(writer, .null, code, errors.default_message(code), null);
        }

        fn batch_array_open_index(input: []const u8) ?usize {
            var i: usize = 0;
            if (input.len >= 3 and input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF) i = 3;
            skip_ascii_whitespace(input, &i);
            if (i >= input.len or input[i] != '[') return null;
            return i;
        }

        fn skip_ascii_whitespace(input: []const u8, index: *usize) void {
            while (index.* < input.len and std.ascii.isWhitespace(input[index.*])) : (index.* += 1) {}
        }

        fn scan_batch_entry_end(input: []const u8, start: usize) scan.ScanRequestError!usize {
            if (start >= input.len) return error.ParseError;
            return switch (input[start]) {
                '{', '[' => scan_composite_end(input, start),
                '"' => scan_string_end(input, start),
                else => scan_primitive_end(input, start),
            };
        }

        fn scan_composite_end(input: []const u8, start: usize) scan.ScanRequestError!usize {
            var depth: usize = 0;
            var in_string = false;
            var escaped = false;
            var i = start;
            while (i < input.len) : (i += 1) {
                const c = input[i];
                if (in_string) {
                    if (escaped) {
                        escaped = false;
                        continue;
                    }
                    if (c == '\\') {
                        escaped = true;
                        continue;
                    }
                    if (c == '"') in_string = false;
                    continue;
                }
                switch (c) {
                    '"' => in_string = true,
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        if (depth == 0) return error.ParseError;
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
            }
            return error.ParseError;
        }

        fn scan_string_end(input: []const u8, start: usize) scan.ScanRequestError!usize {
            var escaped = false;
            var i = start + 1;
            while (i < input.len) : (i += 1) {
                const c = input[i];
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (c == '\\') {
                    escaped = true;
                    continue;
                }
                if (c == '"') return i + 1;
                if (c < 0x20) return error.ParseError;
            }
            return error.ParseError;
        }

        fn scan_primitive_end(input: []const u8, start: usize) scan.ScanRequestError!usize {
            var i = start;
            while (i < input.len) : (i += 1) {
                const c = input[i];
                if (c == ',' or c == ']' or std.ascii.isWhitespace(c)) break;
            }
            if (i == start) return error.ParseError;
            return i;
        }
    };
}

/// Validate JSON-RPC batch size against server configuration.
///
/// Mirrors Nethermind behavior: unauthenticated requests are limited by
/// `max_batch_size`; authenticated contexts bypass this check.
///
/// Returns `null` when accepted, otherwise `.limit_exceeded`.
fn validate_batch_size(config: RpcServerConfig, batch_size: usize, is_authenticated: bool) ?errors.JsonRpcErrorCode {
    if (is_authenticated) return null;
    if (batch_size > config.max_batch_size) return errors.code.limit_exceeded;
    return null;
}

/// Top-level request kind used by the pre-dispatch request pipeline.
const RequestKind = union(enum) {
    object,
    batch: usize,
};

/// Pre-dispatch parse result with either request kind or EIP-1474 error code.
const ParseRequestKindResult = union(enum) {
    request: RequestKind,
    err: errors.JsonRpcErrorCode,
};

/// Parsed single-request dispatch metadata produced from one scan pass.
const DispatchMethod = enum {
    eth_chainId,
    net_version,
    web3_clientVersion,
    web3_sha3,
    unknown,
};

const ExtractMethodNameResult = union(enum) {
    name: []const u8,
    err: errors.JsonRpcErrorCode,
};

fn extract_method_name(request: []const u8, fields: scan.RequestFieldSpans) ExtractMethodNameResult {
    const method_span = fields.method orelse return .{ .err = errors.code.invalid_request };
    const method_token = request[method_span.start..method_span.end];
    if (method_token.len < 2 or method_token[0] != '"' or method_token[method_token.len - 1] != '"') {
        return .{ .err = errors.code.invalid_request };
    }
    return .{ .name = method_token[1 .. method_token.len - 1] };
}

fn resolve_dispatch_method(method_name: []const u8) DispatchMethod {
    if (jsonrpc.eth.EthMethod.fromMethodName(method_name)) |tag| {
        return switch (tag) {
            .eth_chainId => .eth_chainId,
            else => .unknown,
        };
    } else |_| {}

    const non_voltaire_method_registry = std.StaticStringMap(DispatchMethod).initComptime(.{
        .{ "net_version", .net_version },
        .{ "web3_clientVersion", .web3_clientVersion },
        .{ "web3_sha3", .web3_sha3 },
    });
    return non_voltaire_method_registry.get(method_name) orelse .unknown;
}

const ParsedSingleRequest = struct {
    method: DispatchMethod,
    id: envelope.RequestId,
};

/// Single-request parse result (namespace + request id), or EIP-1474 error code.
const ParseSingleRequestResult = union(enum) {
    request: ParsedSingleRequest,
    err: errors.JsonRpcErrorCode,
};

/// Parse top-level request shape and enforce batch limits before dispatch.
///
/// Mirrors Nethermind's object-vs-array split in `JsonRpcProcessor`:
/// - object: routed to single-request method dispatch
/// - array: count entries and enforce `max_batch_size` for unauthenticated calls
fn parse_request_kind_for_dispatch(config: RpcServerConfig, request: []const u8, is_authenticated: bool) ParseRequestKindResult {
    var i: usize = 0;
    if (request.len >= 3 and request[0] == 0xEF and request[1] == 0xBB and request[2] == 0xBF) i = 3;
    while (i < request.len and std.ascii.isWhitespace(request[i])) : (i += 1) {}
    if (i >= request.len) return .{ .err = errors.code.parse_error };

    return switch (request[i]) {
        '{' => .{ .request = .object },
        '[' => blk: {
            const kind = scan.parse_top_level_request_kind(request) catch |err| break :blk .{ .err = scan.scan_error_to_jsonrpc_error(err) };
            switch (kind) {
                .object => unreachable,
                .array => |batch_size| {
                    if (validate_batch_size(config, batch_size, is_authenticated)) |code| {
                        break :blk .{ .err = code };
                    }
                    break :blk .{ .request = .{ .batch = batch_size } };
                },
            }
        },
        else => blk: {
            scan.validate_top_level_json_value(request) catch |err| {
                break :blk .{ .err = scan.scan_error_to_jsonrpc_error(err) };
            };
            break :blk .{ .err = errors.code.invalid_request };
        },
    };
}

/// Parse a single JSON-RPC request once and return routing metadata.
///
/// This combines:
/// - top-level `jsonrpc` validation
/// - method namespace resolution
/// - request-id extraction (including notification detection)
///
/// ...without reparsing the same payload in dispatch and handler stages.
fn parse_single_request_for_dispatch(request: []const u8) ParseSingleRequestResult {
    const fields = switch (scan.scan_and_validate_request_fields(request)) {
        .fields => |value| value,
        .err => |code| return .{ .err = code },
    };

    const method_name = switch (extract_method_name(request, fields)) {
        .name => |value| value,
        .err => |code| return .{ .err = code },
    };

    const request_id = switch (envelope.extract_request_id_from_fields(request, fields)) {
        .id => |rid| rid,
        .err => |code| return .{ .err = code },
    };

    return .{ .request = .{ .method = resolve_dispatch_method(method_name), .id = request_id } };
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
    try std.testing.expectEqual(errors.code.invalid_request, validate_request_jsonrpc_version(req).?);
}

test "validate_request_jsonrpc_version rejects empty request object" {
    try std.testing.expectEqual(errors.code.invalid_request, validate_request_jsonrpc_version("{}").?);
}

test "validate_request_jsonrpc_version rejects unsupported version" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"1.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expectEqual(errors.code.jsonrpc_version_not_supported, validate_request_jsonrpc_version(req).?);
}

test "validate_request_jsonrpc_version applies last-wins semantics for duplicate jsonrpc keys" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"jsonrpc\": \"1.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expectEqual(errors.code.jsonrpc_version_not_supported, validate_request_jsonrpc_version(req).?);
}

test "validate_request_jsonrpc_version accepts duplicate jsonrpc when final value is 2.0" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"1.0\",\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expect(validate_request_jsonrpc_version(req) == null);
}

test "validate_request_jsonrpc_version rejects non-string version token" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": 2.0,\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expectEqual(errors.code.invalid_request, validate_request_jsonrpc_version(req).?);
}

test "validate_request_jsonrpc_version returns parse_error on unterminated version string" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0,\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";
    try std.testing.expectEqual(errors.code.parse_error, validate_request_jsonrpc_version(req).?);
}

test "validate_request_jsonrpc_version returns parse_error on invalid utf8 json" {
    const req = "{ \"jsonrpc\": \"2.0\", \"method\": \"\x80\" }";
    try std.testing.expectEqual(errors.code.parse_error, validate_request_jsonrpc_version(req).?);
}

test "validate_batch_size accepts batches at configured limit" {
    const cfg = RpcServerConfig{ .max_batch_size = 4 };
    try std.testing.expect(validate_batch_size(cfg, 4, false) == null);
}

test "validate_batch_size rejects oversized unauthenticated batches" {
    const cfg = RpcServerConfig{ .max_batch_size = 4 };
    try std.testing.expectEqual(errors.code.limit_exceeded, validate_batch_size(cfg, 5, false).?);
}

test "validate_batch_size allows oversized authenticated batches" {
    const cfg = RpcServerConfig{ .max_batch_size = 4 };
    try std.testing.expect(validate_batch_size(cfg, 10, true) == null);
}

test "parse_request_kind_for_dispatch classifies single request object" {
    const cfg = RpcServerConfig{ .max_batch_size = 4 };
    const req = "{ \"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"eth_chainId\", \"params\": [] }";
    const res = parse_request_kind_for_dispatch(cfg, req, false);
    switch (res) {
        .request => |kind| try std.testing.expect(kind == .object),
        .err => |_| return error.UnexpectedError,
    }
}

test "parse_request_kind_for_dispatch classifies batch and counts entries" {
    const cfg = RpcServerConfig{ .max_batch_size = 4 };
    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_blockNumber\",\"params\":[]}\n" ++
        "]";
    const res = parse_request_kind_for_dispatch(cfg, req, false);
    switch (res) {
        .request => |kind| switch (kind) {
            .batch => |count| try std.testing.expectEqual(@as(usize, 2), count),
            else => return error.UnexpectedVariant,
        },
        .err => |_| return error.UnexpectedError,
    }
}

test "parse_request_kind_for_dispatch rejects oversized unauthenticated batch" {
    const cfg = RpcServerConfig{ .max_batch_size = 1 };
    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_blockNumber\",\"params\":[]}\n" ++
        "]";
    const res = parse_request_kind_for_dispatch(cfg, req, false);
    switch (res) {
        .request => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.limit_exceeded, code),
    }
}

test "parse_request_kind_for_dispatch allows oversized authenticated batch" {
    const cfg = RpcServerConfig{ .max_batch_size = 1 };
    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_blockNumber\",\"params\":[]}\n" ++
        "]";
    const res = parse_request_kind_for_dispatch(cfg, req, true);
    switch (res) {
        .request => |kind| switch (kind) {
            .batch => |count| try std.testing.expectEqual(@as(usize, 2), count),
            else => return error.UnexpectedVariant,
        },
        .err => |_| return error.UnexpectedError,
    }
}

test "parse_request_kind_for_dispatch rejects non-object non-array request roots" {
    const cfg = RpcServerConfig{};
    const res = parse_request_kind_for_dispatch(cfg, "\"hello\"", false);
    switch (res) {
        .request => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.invalid_request, code),
    }
}

test "parse_request_kind_for_dispatch returns parse_error for malformed primitive roots" {
    const cfg = RpcServerConfig{};
    const res = parse_request_kind_for_dispatch(cfg, "\"hello", false);
    switch (res) {
        .request => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.parse_error, code),
    }
}

test "parse_request_kind_for_dispatch returns parse_error for malformed json" {
    const cfg = RpcServerConfig{};
    const res = parse_request_kind_for_dispatch(cfg, "[{\"jsonrpc\":\"2.0\"}", false);
    switch (res) {
        .request => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.parse_error, code),
    }
}

test "parse_request_kind_for_dispatch rejects empty batches as invalid_request" {
    const cfg = RpcServerConfig{};
    const res = parse_request_kind_for_dispatch(cfg, "[]", false);
    switch (res) {
        .request => |_| return error.UnexpectedSuccess,
        .err => |code| try std.testing.expectEqual(errors.code.invalid_request, code),
    }
}

test "parse_single_request_for_dispatch returns dispatch method and numeric id in one pass" {
    const req = "{ \"jsonrpc\": \"2.0\", \"id\": 7, \"method\": \"eth_chainId\", \"params\": [] }";
    const out = parse_single_request_for_dispatch(req);
    switch (out) {
        .request => |parsed| {
            try std.testing.expectEqual(DispatchMethod.eth_chainId, parsed.method);
            switch (parsed.id) {
                .present => |id| switch (id) {
                    .number => |tok| try std.testing.expectEqualStrings("7", tok),
                    else => return error.UnexpectedVariant,
                },
                else => return error.UnexpectedVariant,
            }
        },
        .err => |_| return error.UnexpectedError,
    }
}

test "parse_single_request_for_dispatch marks notifications when id is missing" {
    const req = "{ \"jsonrpc\": \"2.0\", \"method\": \"eth_chainId\", \"params\": [] }";
    const out = parse_single_request_for_dispatch(req);
    switch (out) {
        .request => |parsed| try std.testing.expect(parsed.id == .missing),
        .err => |_| return error.UnexpectedError,
    }
}

test "parse_single_request_for_dispatch marks unknown methods for response-stage handling" {
    const req = "{ \"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"foo_bar\", \"params\": [] }";
    const out = parse_single_request_for_dispatch(req);
    switch (out) {
        .request => |parsed| try std.testing.expectEqual(DispatchMethod.unknown, parsed.method),
        .err => |_| return error.UnexpectedError,
    }
}

test "SingleRequestProcessor.init + handle routes eth_chainId" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Processor = SingleRequestProcessor(ProviderEth, ProviderNet, ProviderWeb3);
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const processor = Processor.init(&eth_provider, &net_provider, &web3_provider);

    const req = "{ \"jsonrpc\": \"2.0\", \"id\": 7, \"method\": \"eth_chainId\", \"params\": [] }";
    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try processor.handle(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"0x1\"}",
        buf.items,
    );
}

test "SingleRequestProcessor.handle routes web3_sha3" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Processor = SingleRequestProcessor(ProviderEth, ProviderNet, ProviderWeb3);
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const processor = Processor.init(&eth_provider, &net_provider, &web3_provider);

    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 11,\n" ++
        "  \"method\": \"web3_sha3\",\n" ++
        "  \"params\": [\"0x68656c6c6f20776f726c64\"]\n" ++
        "}";
    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try processor.handle(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":\"0x47173285a8d7341e5e972fc677286384f802f8ef42a5ec5f03bbfa254cb01fad\"}",
        buf.items,
    );
}

test "SingleRequestProcessor.handle returns method_not_found for unknown method with id" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Processor = SingleRequestProcessor(ProviderEth, ProviderNet, ProviderWeb3);
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const processor = Processor.init(&eth_provider, &net_provider, &web3_provider);

    const req = "{ \"jsonrpc\": \"2.0\", \"id\": \"abc\", \"method\": \"foo_bar\", \"params\": [] }";
    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try processor.handle(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
        buf.items,
    );
}

test "SingleRequestProcessor.handle emits no response for unknown notification" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Processor = SingleRequestProcessor(ProviderEth, ProviderNet, ProviderWeb3);
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const processor = Processor.init(&eth_provider, &net_provider, &web3_provider);

    const req = "{ \"jsonrpc\": \"2.0\", \"method\": \"foo_bar\", \"params\": [] }";
    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try processor.handle(buf.writer(), req);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "BatchRequestExecutor.init + handle routes batch and omits notifications" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Executor = BatchRequestExecutor(ProviderEth, ProviderNet, ProviderWeb3);
    const cfg = RpcServerConfig{ .max_batch_size = 8 };
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const executor = Executor.init(std.testing.allocator, cfg, &eth_provider, &net_provider, &web3_provider);

    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"method\":\"web3_clientVersion\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":\"n1\",\"method\":\"net_version\",\"params\":[]}\n" ++
        "]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try executor.handle(buf.writer(), req, false);
    try std.testing.expectEqualStrings(
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x1\"},{\"jsonrpc\":\"2.0\",\"id\":\"n1\",\"result\":\"1\"}]",
        buf.items,
    );
}

test "BatchRequestExecutor.handle emits no response when batch is notifications only" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Executor = BatchRequestExecutor(ProviderEth, ProviderNet, ProviderWeb3);
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const executor = Executor.init(std.testing.allocator, RpcServerConfig{}, &eth_provider, &net_provider, &web3_provider);

    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"method\":\"web3_clientVersion\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"method\":\"foo_bar\",\"params\":[]}\n" ++
        "]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try executor.handle(buf.writer(), req, false);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "BatchRequestExecutor.handle rejects oversized unauthenticated batch" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Executor = BatchRequestExecutor(ProviderEth, ProviderNet, ProviderWeb3);
    const cfg = RpcServerConfig{ .max_batch_size = 1 };
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const executor = Executor.init(std.testing.allocator, cfg, &eth_provider, &net_provider, &web3_provider);

    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_chainId\",\"params\":[]}\n" ++
        "]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try executor.handle(buf.writer(), req, false);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32005,\"message\":\"Limit exceeded\"}}",
        buf.items,
    );
}

test "BatchRequestExecutor.handle allows oversized authenticated batch" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Executor = BatchRequestExecutor(ProviderEth, ProviderNet, ProviderWeb3);
    const cfg = RpcServerConfig{ .max_batch_size = 1 };
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const executor = Executor.init(std.testing.allocator, cfg, &eth_provider, &net_provider, &web3_provider);

    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_chainId\",\"params\":[]}\n" ++
        "]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try executor.handle(buf.writer(), req, true);
    try std.testing.expectEqualStrings(
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x1\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"0x1\"}]",
        buf.items,
    );
}

test "BatchRequestExecutor.handle includes per-entry invalid_request errors" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Executor = BatchRequestExecutor(ProviderEth, ProviderNet, ProviderWeb3);
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const executor = Executor.init(std.testing.allocator, RpcServerConfig{}, &eth_provider, &net_provider, &web3_provider);

    const req =
        "[\n" ++
        "  1,\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_chainId\",\"params\":[]}\n" ++
        "]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try executor.handle(buf.writer(), req, false);
    try std.testing.expectEqualStrings(
        "[{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid request\"}},{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"0x1\"}]",
        buf.items,
    );
}

test "BatchRequestExecutor.handle enforces max batch response body size for unauthenticated requests" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Executor = BatchRequestExecutor(ProviderEth, ProviderNet, ProviderWeb3);
    const cfg = RpcServerConfig{
        .max_batch_size = 8,
        .max_batch_response_body_size = 1,
    };
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const executor = Executor.init(std.testing.allocator, cfg, &eth_provider, &net_provider, &web3_provider);

    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_chainId\",\"params\":[]}\n" ++
        "]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try executor.handle(buf.writer(), req, false);
    try std.testing.expectEqualStrings(
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x1\"}]",
        buf.items,
    );
}

test "BatchRequestExecutor.handle ignores max batch response body size for authenticated requests" {
    const ProviderEth = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const ProviderNet = struct {
        pub fn getNetworkId(_: *const @This()) @import("voltaire").NetworkId.NetworkId {
            return @import("voltaire").NetworkId.MAINNET;
        }
    };
    const ProviderWeb3 = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/test";
        }
    };

    const Executor = BatchRequestExecutor(ProviderEth, ProviderNet, ProviderWeb3);
    const cfg = RpcServerConfig{
        .max_batch_size = 8,
        .max_batch_response_body_size = 1,
    };
    const eth_provider = ProviderEth{};
    const net_provider = ProviderNet{};
    const web3_provider = ProviderWeb3{};
    const executor = Executor.init(std.testing.allocator, cfg, &eth_provider, &net_provider, &web3_provider);

    const req =
        "[\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]},\n" ++
        "  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_chainId\",\"params\":[]}\n" ++
        "]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try executor.handle(buf.writer(), req, true);
    try std.testing.expectEqualStrings(
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x1\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"0x1\"}]",
        buf.items,
    );
}
