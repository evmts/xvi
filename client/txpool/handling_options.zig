const std = @import("std");

/// Transaction submission handling flags (Nethermind TxHandlingOptions parity).
///
/// These options are carried by txpool submission flows to alter admission /
/// broadcast behavior for local transactions.
pub const TxHandlingOptions = struct {
    const Self = @This();
    pub const Error = error{InvalidTxHandlingOptions};

    pub const Int = u32;
    bits: Int,

    pub const none = TxHandlingOptions{ .bits = 0 };

    /// Tries to find the valid nonce for the given account.
    pub const managed_nonce = TxHandlingOptions{ .bits = 1 << 0 };
    /// Keeps trying to push the transaction until it is included in a block.
    pub const persistent_broadcast = TxHandlingOptions{ .bits = 1 << 1 };
    /// Old-style signature without replay attack protection (pre-EIP-155).
    pub const pre_eip155_signing = TxHandlingOptions{ .bits = 1 << 2 };
    /// Allows replacing transaction signature even if already signed.
    pub const allow_replacing_signature = TxHandlingOptions{ .bits = 1 << 3 };

    /// Bitmask containing every declared option flag.
    pub const all = TxHandlingOptions{
        .bits = managed_nonce.bits |
            persistent_broadcast.bits |
            pre_eip155_signing.bits |
            allow_replacing_signature.bits,
    };

    /// Builds an option set from raw bits and rejects unknown flags.
    pub fn from_bits(bits: Int) Error!Self {
        const options = Self{ .bits = bits };
        try options.validate();
        return options;
    }

    /// Drops any unknown bits and returns only declared flags.
    pub fn sanitize(self: Self) Self {
        return .{ .bits = self.bits & all.bits };
    }

    /// Returns true when all bits map to declared option flags.
    pub fn is_valid(self: Self) bool {
        return self.bits == self.sanitize().bits;
    }

    /// Returns `error.InvalidTxHandlingOptions` when unknown flags are present.
    pub fn validate(self: Self) Error!void {
        if (!self.is_valid()) return error.InvalidTxHandlingOptions;
    }

    /// Combines two option sets after sanitizing both operands.
    pub fn merge(self: Self, other: Self) Self {
        const lhs = self.sanitize();
        const rhs = other.sanitize();
        return .{ .bits = lhs.bits | rhs.bits };
    }

    /// Returns true when `self` contains all flags set in `other`.
    pub fn has(self: Self, other: Self) bool {
        if (!self.is_valid() or !other.is_valid()) return false;
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
    try std.testing.expectEqual(@as(TxHandlingOptions.Int, 0), TxHandlingOptions.none.bits);
    try std.testing.expectEqual(@as(TxHandlingOptions.Int, 1), TxHandlingOptions.managed_nonce.bits);
    try std.testing.expectEqual(@as(TxHandlingOptions.Int, 2), TxHandlingOptions.persistent_broadcast.bits);
    try std.testing.expectEqual(@as(TxHandlingOptions.Int, 4), TxHandlingOptions.pre_eip155_signing.bits);
    try std.testing.expectEqual(@as(TxHandlingOptions.Int, 8), TxHandlingOptions.allow_replacing_signature.bits);
    try std.testing.expectEqual(@as(TxHandlingOptions.Int, 15), TxHandlingOptions.all.bits);
}

test "TxHandlingOptions merge and has" {
    const merged = TxHandlingOptions.managed_nonce.merge(TxHandlingOptions.persistent_broadcast);
    try std.testing.expect(merged.has(TxHandlingOptions.managed_nonce));
    try std.testing.expect(merged.has(TxHandlingOptions.persistent_broadcast));
    try std.testing.expect(!merged.has(TxHandlingOptions.pre_eip155_signing));
    try std.testing.expect(TxHandlingOptions.all.has(TxHandlingOptions.allow_replacing_signature));
}

test "TxHandlingOptions reject invalid flag domains and sanitize merges" {
    const invalid = TxHandlingOptions{ .bits = 0xff };

    try std.testing.expect(!invalid.is_valid());
    try std.testing.expectEqual(TxHandlingOptions.all.bits, invalid.sanitize().bits);
    try std.testing.expectError(error.InvalidTxHandlingOptions, TxHandlingOptions.from_bits(0xff));

    // Invalid states are rejected by `has` to keep the domain closed.
    try std.testing.expect(!invalid.has(TxHandlingOptions.managed_nonce));

    // Merge sanitizes both sides, keeping only declared flags.
    const merged = invalid.merge(TxHandlingOptions.none);
    try std.testing.expectEqual(TxHandlingOptions.all.bits, merged.bits);
}
