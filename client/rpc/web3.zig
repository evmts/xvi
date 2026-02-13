//! Ethereum JSON-RPC (web3_*) minimal handlers.
//!
//! Implements `web3_clientVersion` per EIP-1474:
//! result is a JSON string describing the current client version.
const std = @import("std");
const envelope = @import("envelope.zig");
const errors = @import("error.zig");
const Response = @import("response.zig").Response;

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

        fn write_success_string(writer: anytype, id: envelope.Id, value: []const u8) !void {
            try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
            try write_id(writer, id);
            try writer.writeAll(",\"result\":");
            try std.json.stringify(value, .{}, writer);
            try writer.writeAll("}");
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
