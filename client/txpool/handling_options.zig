const std = @import("std");

/// Transaction submission handling flags (Nethermind TxHandlingOptions parity).
///
/// These options are carried by txpool submission flows to alter admission /
/// broadcast behavior for local transactions.
pub const TxHandlingOptions = struct {
    bits: u8,

    pub const none = TxHandlingOptions{ .bits = 0 };

    /// Tries to find the valid nonce for the given account.
    pub const managed_nonce = TxHandlingOptions{ .bits = 1 << 0 };
    /// Keeps trying to push the transaction until it is included in a block.
    pub const persistent_broadcast = TxHandlingOptions{ .bits = 1 << 1 };
    /// Old-style signature without replay attack protection (pre-EIP-155).
    pub const pre_eip155_signing = TxHandlingOptions{ .bits = 1 << 2 };
    /// Allows replacing transaction signature even if already signed.
    pub const allow_replacing_signature = TxHandlingOptions{ .bits = 1 << 3 };

    pub const all = TxHandlingOptions{
        .bits = managed_nonce.bits |
            persistent_broadcast.bits |
            pre_eip155_signing.bits |
            allow_replacing_signature.bits,
    };

    pub fn merge(self: TxHandlingOptions, other: TxHandlingOptions) TxHandlingOptions {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn has(self: TxHandlingOptions, other: TxHandlingOptions) bool {
        return (self.bits & other.bits) == other.bits;
    }
};

comptime {
    if (TxHandlingOptions.none.bits != 0) @compileError("TxHandlingOptions.none must be 0");
    if (TxHandlingOptions.managed_nonce.bits != (1 << 0)) @compileError("TxHandlingOptions.managed_nonce must be bit 0");
    if (TxHandlingOptions.persistent_broadcast.bits != (1 << 1)) @compileError("TxHandlingOptions.persistent_broadcast must be bit 1");
    if (TxHandlingOptions.pre_eip155_signing.bits != (1 << 2)) @compileError("TxHandlingOptions.pre_eip155_signing must be bit 2");
    if (TxHandlingOptions.allow_replacing_signature.bits != (1 << 3)) @compileError("TxHandlingOptions.allow_replacing_signature must be bit 3");

    const expected_all = TxHandlingOptions.managed_nonce.bits |
        TxHandlingOptions.persistent_broadcast.bits |
        TxHandlingOptions.pre_eip155_signing.bits |
        TxHandlingOptions.allow_replacing_signature.bits;
    if (TxHandlingOptions.all.bits != expected_all) @compileError("TxHandlingOptions.all must be OR of all flags");
}

test "TxHandlingOptions bit layout and composition mirror Nethermind" {
    try std.testing.expectEqual(@as(u8, 0), TxHandlingOptions.none.bits);
    try std.testing.expectEqual(@as(u8, 1), TxHandlingOptions.managed_nonce.bits);
    try std.testing.expectEqual(@as(u8, 2), TxHandlingOptions.persistent_broadcast.bits);
    try std.testing.expectEqual(@as(u8, 4), TxHandlingOptions.pre_eip155_signing.bits);
    try std.testing.expectEqual(@as(u8, 8), TxHandlingOptions.allow_replacing_signature.bits);
    try std.testing.expectEqual(@as(u8, 15), TxHandlingOptions.all.bits);
}

test "TxHandlingOptions merge and has" {
    const merged = TxHandlingOptions.managed_nonce.merge(TxHandlingOptions.persistent_broadcast);
    try std.testing.expect(merged.has(TxHandlingOptions.managed_nonce));
    try std.testing.expect(merged.has(TxHandlingOptions.persistent_broadcast));
    try std.testing.expect(!merged.has(TxHandlingOptions.pre_eip155_signing));
    try std.testing.expect(TxHandlingOptions.all.has(TxHandlingOptions.allow_replacing_signature));
}
