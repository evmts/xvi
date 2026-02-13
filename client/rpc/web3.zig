//! Ethereum JSON-RPC (web3_*) minimal handlers.
//!
//! Implements `web3_clientVersion` and `web3_sha3` per EIP-1474:
//! - clientVersion result is a JSON string describing the current client version.
//! - sha3 accepts exactly one `Data` parameter and returns `Data` hash bytes.
const std = @import("std");
const crypto = @import("crypto");
const envelope = @import("envelope.zig");
const errors = @import("error.zig");
const scan = @import("scan.zig");
const Response = @import("response.zig").Response;
const Hash32 = @import("primitives").Hash.Hash;

/// Generic WEB3 API surface (comptime-injected provider).
///
/// The `Provider` type must define:
/// - `pub fn getClientVersion(self: *const Provider) []const u8`
pub fn Web3Api(comptime Provider: type) type {
    comptime {
        if (!@hasDecl(Provider, "getClientVersion")) {
            @compileError("Web3Api Provider must define getClientVersion(self: *const Provider) []const u8");
        }
        const Fn = @TypeOf(Provider.getClientVersion);
        const ti = @typeInfo(Fn);
        if (ti != .@"fn") @compileError("getClientVersion must be a function");
        if (ti.@"fn".params.len != 1 or ti.@"fn".params[0].type == null) {
            @compileError("getClientVersion must take exactly one parameter: *const Provider");
        }
        const P0 = ti.@"fn".params[0].type.?;
        if (@typeInfo(P0) != .pointer or @typeInfo(P0).pointer.is_const != true or @typeInfo(P0).pointer.child != Provider) {
            @compileError("getClientVersion param must be of type *const Provider");
        }
        const Ret = ti.@"fn".return_type orelse @compileError("getClientVersion must return []const u8");
        if (Ret != []const u8) @compileError("getClientVersion must return []const u8");
    }

    return struct {
        const Self = @This();

        provider: *const Provider,

        /// Handle `web3_clientVersion` for an already extracted request-id.
        ///
        /// - Uses pre-parsed request id from the dispatch pipeline.
        /// - Notifications (`id` missing) do not emit any response.
        /// - On success, returns a JSON string result.
        pub fn handle_client_version(self: *const Self, writer: anytype, request_id: envelope.RequestId) !void {
            switch (request_id) {
                .missing => return, // JSON-RPC notification: no response
                .present => |id| {
                    const version = self.provider.getClientVersion();
                    try write_success_string(writer, id, version);
                },
            }
        }

        /// Convenience wrapper that extracts request id from raw request bytes.
        ///
        /// Prefer using `handle_client_version` with a pre-parsed id to avoid
        /// reparsing in the hot request path.
        pub fn handle_client_version_from_request(self: *const Self, writer: anytype, request_bytes: []const u8) !void {
            const id_res = envelope.extract_request_id(request_bytes);
            switch (id_res) {
                .id => |rid| try self.handle_client_version(writer, rid),
                .err => |code| {
                    try Response.write_error(writer, .null, code, errors.default_message(code), null);
                },
            }
        }

        /// Handle `web3_sha3` for an already extracted request-id.
        ///
        /// - Expects a single EIP-1474 `Data` value as `data_hex`.
        /// - Notifications (`id` missing) do not emit any response.
        /// - Invalid `Data` produces `-32602 Invalid params`.
        pub fn handle_sha3(self: *const Self, writer: anytype, request_id: envelope.RequestId, data_hex: []const u8) !void {
            _ = self;
            switch (request_id) {
                .missing => return, // JSON-RPC notification: no response
                .present => |id| {
                    const digest = keccak256_from_data_hex(data_hex) catch {
                        const code = errors.code.invalid_params;
                        try Response.write_error(writer, id, code, errors.default_message(code), null);
                        return;
                    };
                    try write_success_data_hash(writer, id, digest);
                },
            }
        }

        /// Convenience wrapper for `web3_sha3` that extracts request-id and params.
        ///
        /// The request must contain exactly one `params` element of EIP-1474
        /// `Data` type (hex string, `0x`-prefixed, two hex chars per byte).
        pub fn handle_sha3_from_request(self: *const Self, writer: anytype, request_bytes: []const u8) !void {
            const fields = switch (scan.scan_and_validate_request_fields(request_bytes)) {
                .fields => |value| value,
                .err => |code| {
                    try Response.write_error(writer, .null, code, errors.default_message(code), null);
                    return;
                },
            };

            const request_id = switch (envelope.extract_request_id_from_fields(request_bytes, fields)) {
                .id => |rid| rid,
                .err => |code| {
                    try Response.write_error(writer, .null, code, errors.default_message(code), null);
                    return;
                },
            };

            switch (request_id) {
                .missing => return, // JSON-RPC notification: no response
                .present => |id| {
                    const data_hex = switch (extract_sha3_param_data(request_bytes)) {
                        .data_hex => |value| value,
                        .err => |code| {
                            try Response.write_error(writer, id, code, errors.default_message(code), null);
                            return;
                        },
                    };
                    try self.handle_sha3(writer, .{ .present = id }, data_hex);
                },
            }
        }

        fn write_success_string(writer: anytype, id: envelope.Id, value: []const u8) !void {
            try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
            try write_id(writer, id);
            try writer.writeAll(",\"result\":");
            try write_json_string(writer, value);
            try writer.writeAll("}");
        }

        fn write_success_data_hash(writer: anytype, id: envelope.Id, hash: Hash32) !void {
            var result_raw: [68]u8 = undefined; // "\"0x" + 64 hex chars + "\""
            result_raw[0] = '"';
            result_raw[1] = '0';
            result_raw[2] = 'x';
            const hex = "0123456789abcdef";
            var i: usize = 3;
            for (hash) |b| {
                const hi: usize = @intCast((b >> 4) & 0x0F);
                const lo: usize = @intCast(b & 0x0F);
                result_raw[i] = hex[hi];
                result_raw[i + 1] = hex[lo];
                i += 2;
            }
            result_raw[i] = '"';
            try Response.write_success_raw(writer, id, &result_raw);
        }

        fn keccak256_from_data_hex(data_hex: []const u8) error{InvalidData}!Hash32 {
            if (data_hex.len < 2 or data_hex[0] != '0' or data_hex[1] != 'x') {
                return error.InvalidData;
            }

            const hex_len = data_hex.len - 2;
            if ((hex_len & 1) != 0) {
                return error.InvalidData;
            }

            var hasher = crypto.Keccak256.init(.{});
            var chunk: [256]u8 = undefined;
            var chunk_len: usize = 0;

            var i: usize = 2;
            while (i < data_hex.len) : (i += 2) {
                const hi = hex_nibble(data_hex[i]) orelse return error.InvalidData;
                const lo = hex_nibble(data_hex[i + 1]) orelse return error.InvalidData;
                chunk[chunk_len] = (hi << 4) | lo;
                chunk_len += 1;
                if (chunk_len == chunk.len) {
                    hasher.update(chunk[0..chunk_len]);
                    chunk_len = 0;
                }
            }

            if (chunk_len > 0) {
                hasher.update(chunk[0..chunk_len]);
            }

            var digest: Hash32 = undefined;
            hasher.final(&digest);
            return digest;
        }

        const ExtractSha3ParamResult = union(enum) {
            data_hex: []const u8,
            err: errors.JsonRpcErrorCode,
        };

        fn extract_sha3_param_data(request: []const u8) ExtractSha3ParamResult {
            const key = "\"params\"";
            const key_idx = find_last_top_level_key(request, key) orelse return .{ .err = errors.code.invalid_params };

            var i = key_idx + key.len;
            skip_whitespace(request, &i);
            if (i >= request.len) return .{ .err = errors.code.parse_error };
            if (request[i] != ':') return .{ .err = errors.code.invalid_request };
            i += 1;
            skip_whitespace(request, &i);
            if (i >= request.len) return .{ .err = errors.code.parse_error };
            if (request[i] != '[') return .{ .err = errors.code.invalid_params };
            i += 1;
            skip_whitespace(request, &i);
            if (i >= request.len) return .{ .err = errors.code.parse_error };
            if (request[i] == ']') return .{ .err = errors.code.invalid_params };

            const data_hex = switch (parse_json_string_value(request, &i)) {
                .value => |v| v,
                .err => |code| return .{ .err = code },
            };

            skip_whitespace(request, &i);
            if (i >= request.len) return .{ .err = errors.code.parse_error };
            if (request[i] == ',') return .{ .err = errors.code.invalid_params };
            if (request[i] != ']') return .{ .err = errors.code.invalid_params };

            return .{ .data_hex = data_hex };
        }

        const ParseJsonStringResult = union(enum) {
            value: []const u8,
            err: errors.JsonRpcErrorCode,
        };

        fn parse_json_string_value(input: []const u8, index: *usize) ParseJsonStringResult {
            if (index.* >= input.len or input[index.*] != '"') return .{ .err = errors.code.invalid_params };
            const start = index.* + 1;
            var i = start;
            var escaped = false;

            while (i < input.len) : (i += 1) {
                const ch = input[i];
                if (escaped) {
                    switch (ch) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
                        'u' => {
                            var n: usize = 0;
                            while (n < 4) : (n += 1) {
                                i += 1;
                                if (i >= input.len or !std.ascii.isHex(input[i])) {
                                    return .{ .err = errors.code.parse_error };
                                }
                            }
                        },
                        else => return .{ .err = errors.code.parse_error },
                    }
                    escaped = false;
                    continue;
                }

                if (ch == '\\') {
                    escaped = true;
                    continue;
                }
                if (ch == '"') {
                    index.* = i + 1;
                    return .{ .value = input[start..i] };
                }
                if (ch < 0x20) return .{ .err = errors.code.parse_error };
            }

            return .{ .err = errors.code.parse_error };
        }

        fn find_last_top_level_key(input: []const u8, key: []const u8) ?usize {
            var depth: u32 = 0;
            var in_string = false;
            var escaped = false;
            var expecting_key = false;
            var found: ?usize = null;
            var i: usize = 0;
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
                    '"' => {
                        if (depth == 1 and expecting_key) {
                            const rem = input[i..];
                            if (rem.len >= key.len and std.mem.eql(u8, rem[0..key.len], key)) {
                                found = i;
                            }
                        }
                        in_string = true;
                    },
                    '{' => {
                        depth += 1;
                        if (depth == 1) expecting_key = true;
                    },
                    '}' => {
                        if (depth == 0) return found;
                        depth -= 1;
                        if (depth == 1) expecting_key = false;
                    },
                    '[' => depth += 1,
                    ']' => {
                        if (depth == 0) return found;
                        depth -= 1;
                    },
                    ':' => {
                        if (depth == 1) expecting_key = false;
                    },
                    ',' => {
                        if (depth == 1) expecting_key = true;
                    },
                    else => {},
                }
            }
            return found;
        }

        fn skip_whitespace(input: []const u8, index: *usize) void {
            while (index.* < input.len and std.ascii.isWhitespace(input[index.*])) : (index.* += 1) {}
        }

        fn hex_nibble(c: u8) ?u8 {
            return switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => null,
            };
        }

        fn write_id(writer: anytype, id: envelope.Id) !void {
            switch (id) {
                .null => try writer.writeAll("null"),
                .number => |tok| try writer.writeAll(tok),
                .string => |raw_between_quotes| {
                    // Re-wrap the raw id bytes extracted from the envelope scanner.
                    try writer.writeAll("\"");
                    try writer.writeAll(raw_between_quotes);
                    try writer.writeAll("\"");
                },
            }
        }

        fn write_json_string(writer: anytype, s: []const u8) !void {
            try writer.writeAll("\"");
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                const c = s[i];
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0x08 => try writer.writeAll("\\b"),
                    0x0C => try writer.writeAll("\\f"),
                    else => if (c < 0x20) {
                        var buf: [6]u8 = .{ '\\', 'u', '0', '0', 0, 0 };
                        const hex = "0123456789abcdef";
                        buf[4] = hex[(c >> 4) & 0xF];
                        buf[5] = hex[c & 0xF];
                        try writer.writeAll(&buf);
                    } else {
                        try writer.writeByte(c);
                    },
                }
            }
            try writer.writeAll("\"");
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Web3Api.handleClientVersion: number id -> JSON string result" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_client_version(buf.writer(), .{ .present = .{ .number = "7" } });
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"xvi/v0.1.0/linux-zig\"}",
        buf.items,
    );
}

test "Web3Api.handleClientVersion: notification id missing emits no response" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_client_version(buf.writer(), .missing);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "Web3Api.handleClientVersionFromRequest: string id preserved" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": \"abc-123\",\n" ++
        "  \"method\": \"web3_clientVersion\",\n" ++
        "  \"params\": []\n" ++
        "}";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_client_version_from_request(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc-123\",\"result\":\"xvi/v0.1.0/linux-zig\"}",
        buf.items,
    );
}

test "Web3Api.handleClientVersionFromRequest: escapes result string" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/\"dev\"\nline";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req = "{ \"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"web3_clientVersion\", \"params\": [] }";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_client_version_from_request(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"xvi/\\\"dev\\\"\\nline\"}",
        buf.items,
    );
}

test "Web3Api.handleClientVersionFromRequest: invalid envelope -> EIP-1474 error with id:null" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    // Batch array at top level is not handled here.
    const bad = "[ { \"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"web3_clientVersion\", \"params\": [] } ]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_client_version_from_request(buf.writer(), bad);

    const code = errors.code.invalid_request;
    var expect_buf: [256]u8 = undefined;
    var fba = std.io.fixedBufferStream(&expect_buf);
    try Response.write_error(fba.writer(), .null, code, errors.default_message(code), null);
    try std.testing.expectEqualStrings(fba.getWritten(), buf.items);
}

test "Web3Api.handleClientVersionFromRequest: explicit id null emits response with id:null" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req = "{ \"jsonrpc\": \"2.0\", \"id\": null, \"method\": \"web3_clientVersion\", \"params\": [] }";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_client_version_from_request(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":\"xvi/v0.1.0/linux-zig\"}",
        buf.items,
    );
}

test "Web3Api.handleClientVersionFromRequest: missing id notification emits no response" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req = "{ \"jsonrpc\": \"2.0\", \"method\": \"web3_clientVersion\", \"params\": [] }";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_client_version_from_request(buf.writer(), req);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "Web3Api.handleSha3: number id -> DATA hash result" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_sha3(buf.writer(), .{ .present = .{ .number = "7" } }, "0x68656c6c6f20776f726c64");
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"0x47173285a8d7341e5e972fc677286384f802f8ef42a5ec5f03bbfa254cb01fad\"}",
        buf.items,
    );
}

test "Web3Api.handleSha3: invalid DATA -> invalid params error" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_sha3(buf.writer(), .{ .present = .{ .string = "bad" } }, "0x0");

    const code = errors.code.invalid_params;
    var expect_buf: [256]u8 = undefined;
    var fba = std.io.fixedBufferStream(&expect_buf);
    try Response.write_error(fba.writer(), .{ .string = "bad" }, code, errors.default_message(code), null);
    try std.testing.expectEqualStrings(fba.getWritten(), buf.items);
}

test "Web3Api.handleSha3FromRequest: valid payload" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": \"abc-123\",\n" ++
        "  \"method\": \"web3_sha3\",\n" ++
        "  \"params\": [\"0x68656c6c6f20776f726c64\"]\n" ++
        "}";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_sha3_from_request(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc-123\",\"result\":\"0x47173285a8d7341e5e972fc677286384f802f8ef42a5ec5f03bbfa254cb01fad\"}",
        buf.items,
    );
}

test "Web3Api.handleSha3FromRequest: invalid DATA payload -> invalid params" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"web3_sha3\",\n" ++
        "  \"params\": [\"0x0\"]\n" ++
        "}";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_sha3_from_request(buf.writer(), req);

    const code = errors.code.invalid_params;
    var expect_buf: [256]u8 = undefined;
    var fba = std.io.fixedBufferStream(&expect_buf);
    try Response.write_error(fba.writer(), .{ .number = "1" }, code, errors.default_message(code), null);
    try std.testing.expectEqualStrings(fba.getWritten(), buf.items);
}

test "Web3Api.handleSha3FromRequest: missing id notification emits no response" {
    const Provider = struct {
        pub fn getClientVersion(_: *const @This()) []const u8 {
            return "xvi/v0.1.0/linux-zig";
        }
    };
    const Api = Web3Api(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req = "{ \"jsonrpc\": \"2.0\", \"method\": \"web3_sha3\", \"params\": [\"0x\"] }";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_sha3_from_request(buf.writer(), req);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}
