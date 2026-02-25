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

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_chain_id(buf.writer(), .{ .present = .{ .number = "7" } });
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

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_chain_id(buf.writer(), .{ .present = .{ .string = "abc-123" } });
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc-123\",\"result\":\"0x1a\"}",
        buf.items,
    );
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

test "EthApi.handleChainId: explicit id null emits response with id:null" {
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
    try api.handle_chain_id(buf.writer(), .{ .present = .null });
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":\"0x1\"}",
        buf.items,
    );
}
