//! Ethereum JSON-RPC (net_*) minimal handlers.
//!
//! Implements `net_version` per execution-apis `eth/client.yaml` and EIP-1474:
//! result is a decimal string network ID (not QUANTITY hex).
const std = @import("std");
const primitives = @import("voltaire");
const envelope = @import("envelope.zig");
const errors = @import("error.zig");
const Response = @import("response.zig").Response;

const NetworkId = primitives.NetworkId.NetworkId;

/// Generic NET API surface (comptime-injected provider).
///
/// The `Provider` type must define:
/// - `pub fn getNetworkId(self: *const Provider) primitives.NetworkId.NetworkId`
pub fn NetApi(comptime Provider: type) type {
    comptime {
        if (!@hasDecl(Provider, "getNetworkId")) {
            @compileError("NetApi Provider must define getNetworkId(self: *const Provider) primitives.NetworkId.NetworkId");
        }
        const Fn = @TypeOf(Provider.getNetworkId);
        const ti = @typeInfo(Fn);
        if (ti != .@"fn") @compileError("getNetworkId must be a function");
        if (ti.@"fn".params.len != 1 or ti.@"fn".params[0].type == null) {
            @compileError("getNetworkId must take exactly one parameter: *const Provider");
        }
        const P0 = ti.@"fn".params[0].type.?;
        if (@typeInfo(P0) != .pointer or @typeInfo(P0).pointer.is_const != true or @typeInfo(P0).pointer.child != Provider) {
            @compileError("getNetworkId param must be of type *const Provider");
        }
        const Ret = ti.@"fn".return_type orelse @compileError("getNetworkId must return primitives.NetworkId.NetworkId");
        if (Ret != NetworkId) @compileError("getNetworkId must return primitives.NetworkId.NetworkId");
    }

    return struct {
        const Self = @This();

        provider: *const Provider,

        /// Handle `net_version` for an already extracted request-id.
        ///
        /// - Uses pre-parsed request id from the dispatch pipeline.
        /// - Notifications (`id` missing) do not emit any response.
        /// - On success, returns decimal-string network ID.
        pub fn handle_version(self: *const Self, writer: anytype, request_id: envelope.RequestId) !void {
            switch (request_id) {
                .missing => return, // JSON-RPC notification: no response
                .present => |id| {
                    const network_id: NetworkId = self.provider.getNetworkId();
                    try Response.write_success_decimal_u64(writer, id, primitives.NetworkId.toNumber(network_id));
                },
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "NetApi.handleVersion: number id -> decimal string result" {
    const Provider = struct {
        pub fn getNetworkId(_: *const @This()) NetworkId {
            return primitives.NetworkId.MAINNET;
        }
    };
    const Api = NetApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_version(buf.writer(), .{ .present = .{ .number = "7" } });
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"1\"}",
        buf.items,
    );
}

test "NetApi.handleVersion: string id preserved" {
    const Provider = struct {
        pub fn getNetworkId(_: *const @This()) NetworkId {
            return primitives.NetworkId.SEPOLIA;
        }
    };
    const Api = NetApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_version(buf.writer(), .{ .present = .{ .string = "abc-123" } });
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc-123\",\"result\":\"11155111\"}",
        buf.items,
    );
}

test "NetApi.handleVersion: notification id missing emits no response" {
    const Provider = struct {
        pub fn getNetworkId(_: *const @This()) NetworkId {
            return primitives.NetworkId.MAINNET;
        }
    };
    const Api = NetApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_version(buf.writer(), .missing);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "NetApi.handleVersion: explicit id null emits response with id:null" {
    const Provider = struct {
        pub fn getNetworkId(_: *const @This()) NetworkId {
            return primitives.NetworkId.MAINNET;
        }
    };
    const Api = NetApi(Provider);
    const provider = Provider{};
    var api = Api{ .provider = &provider };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try api.handle_version(buf.writer(), .{ .present = .null });
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":\"1\"}",
        buf.items,
    );
}
