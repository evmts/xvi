//! Ethereum JSON-RPC (eth_*) minimal handlers.
//!
//! Implements `eth_chainId` per EIP-1474 using Voltaire JSON-RPC types
//! and allocation-free response serializers. Configuration is injected
//! via a small comptime provider with a `getChainId() u64` method.
const std = @import("std");
const jsonrpc = @import("jsonrpc");
const envelope = @import("envelope.zig");
const errors = @import("error.zig");
const Response = @import("response.zig").Response;

/// Generic ETH API surface (comptime-injected provider).
///
/// The `Provider` type must define:
/// - `pub fn getChainId(self: *const Provider) u64`
pub fn EthApi(comptime Provider: type) type {
    // Compile-time contract for Provider
    comptime {
        if (!@hasDecl(Provider, "getChainId")) {
            @compileError("EthApi Provider must define getChainId(self: *const Provider) u64");
        }
        const Fn = @TypeOf(Provider.getChainId);
        const ti = @typeInfo(Fn);
        if (ti != .@"fn") @compileError("getChainId must be a function");
        if (ti.@"fn".params.len != 1 or ti.@"fn".params[0].type == null) {
            @compileError("getChainId must take exactly one parameter: *const Provider");
        }
        const P0 = ti.@"fn".params[0].type.?;
        if (@typeInfo(P0) != .pointer or @typeInfo(P0).pointer.is_const != true or @typeInfo(P0).pointer.child != Provider) {
            @compileError("getChainId param must be of type *const Provider");
        }
        const Ret = ti.@"fn".return_type orelse @compileError("getChainId must return u64");
        if (Ret != u64) @compileError("getChainId must return u64");
    }

    return struct {
        const Self = @This();

        provider: *const Provider,

        /// Handle `eth_chainId` for an already extracted request-id.
        ///
        /// - Uses pre-parsed request id from the dispatch pipeline.
        /// - Notifications (`id` missing) do not emit any response.
        /// - On success, returns QUANTITY(u64) per EIP-1474.
        pub fn handle_chain_id(self: *const Self, writer: anytype, request_id: envelope.RequestId) !void {
            // Keep shapes aligned with Voltaire types for eth_chainId
            const EthMethod = jsonrpc.eth.EthMethod;
            const ChainIdShape = @FieldType(EthMethod, "eth_chainId"); // { params, result }
            _ = ChainIdShape; // referenced to ensure compile-time coupling

            switch (request_id) {
                .missing => return, // JSON-RPC notification: no response
                .present => |id| {
                    const chain_id: u64 = self.provider.getChainId();
                    try Response.write_success_quantity_u64(writer, id, chain_id);
                },
            }
        }

        /// Convenience wrapper that extracts request id from raw request bytes.
        ///
        /// Prefer using `handle_chain_id` with a pre-parsed id to avoid reparsing
        /// in the hot request path.
        pub fn handle_chain_id_from_request(self: *const Self, writer: anytype, request_bytes: []const u8) !void {
            const id_res = envelope.extract_request_id(request_bytes);
            switch (id_res) {
                .id => |rid| try self.handle_chain_id(writer, rid),
                .err => |code| {
                    // Per EIP-1474, when id cannot be determined, respond with id:null
                    try Response.write_error(writer, .null, code, errors.default_message(code), null);
                },
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "EthApi.handleChainId: number id -> QUANTITY result" {
    const Provider = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const Api = EthApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 7,\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_chain_id_from_request(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"0x1\"}",
        buf.items,
    );
}

test "EthApi.handleChainId: string id preserved; QUANTITY encoding" {
    const Provider = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 26;
        }
    };
    const Api = EthApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": \"abc-123\",\n" ++
        "  \"method\": \"eth_chainId\",\n" ++
        "  \"params\": []\n" ++
        "}";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_chain_id_from_request(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc-123\",\"result\":\"0x1a\"}",
        buf.items,
    );
}

test "EthApi.handleChainId: invalid envelope -> EIP-1474 error with id:null" {
    const Provider = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const Api = EthApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    // Batch array at top level is not handled here
    const bad = "[ { \"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"eth_chainId\", \"params\": [] } ]";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_chain_id_from_request(buf.writer(), bad);

    const code = errors.code.invalid_request;
    var expect_buf: [256]u8 = undefined;
    var fba = std.io.fixedBufferStream(&expect_buf);
    try Response.write_error(fba.writer(), .null, code, errors.default_message(code), null);
    try std.testing.expectEqualStrings(fba.getWritten(), buf.items);
}

test "EthApi.handleChainId: notification id missing emits no response" {
    const Provider = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const Api = EthApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_chain_id(buf.writer(), .missing);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "EthApi.handleChainIdFromRequest: explicit id null emits response with id:null" {
    const Provider = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const Api = EthApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req = "{ \"jsonrpc\": \"2.0\", \"id\": null, \"method\": \"eth_chainId\", \"params\": [] }";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_chain_id_from_request(buf.writer(), req);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":\"0x1\"}",
        buf.items,
    );
}

test "EthApi.handleChainIdFromRequest: missing id notification emits no response" {
    const Provider = struct {
        pub fn getChainId(_: *const @This()) u64 {
            return 1;
        }
    };
    const Api = EthApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    const req = "{ \"jsonrpc\": \"2.0\", \"method\": \"eth_chainId\", \"params\": [] }";

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_chain_id_from_request(buf.writer(), req);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}
