const std = @import("std");

/// Admission outcome for txpool intake.
///
/// Mirrors Nethermind's `AcceptTxResult` catalog while remaining
/// allocation-free and value-semantic in Zig.
pub const AcceptTxResult = struct {
    id: u16,
    code: []const u8,
    message: ?[]const u8 = null,

    pub const accepted = AcceptTxResult{ .id = 0, .code = "Accepted" };
    pub const already_known = AcceptTxResult{ .id = 1, .code = "AlreadyKnown" };
    pub const failed_to_resolve_sender = AcceptTxResult{ .id = 2, .code = "FailedToResolveSender" };
    pub const fee_too_low = AcceptTxResult{ .id = 3, .code = "FeeTooLow" };
    pub const fee_too_low_to_compete = AcceptTxResult{ .id = 4, .code = "FeeTooLowToCompete" };
    pub const gas_limit_exceeded = AcceptTxResult{ .id = 5, .code = "gas limit reached" };
    pub const insufficient_funds = AcceptTxResult{ .id = 6, .code = "InsufficientFunds" };
    pub const int256_overflow = AcceptTxResult{ .id = 7, .code = "Int256Overflow" };
    pub const invalid = AcceptTxResult{ .id = 8, .code = "Invalid" };
    pub const nonce_gap = AcceptTxResult{ .id = 9, .code = "nonce too high" };
    pub const old_nonce = AcceptTxResult{ .id = 10, .code = "nonce too low" };
    pub const replacement_not_allowed = AcceptTxResult{ .id = 11, .code = "ReplacementNotAllowed" };
    pub const sender_is_contract = AcceptTxResult{ .id = 12, .code = "sender not an eoa" };
    pub const nonce_too_far_in_future = AcceptTxResult{ .id = 13, .code = "NonceTooFarInFuture" };
    pub const pending_txs_of_conflicting_type = AcceptTxResult{ .id = 14, .code = "PendingTxsOfConflictingType" };
    pub const not_supported_tx_type = AcceptTxResult{ .id = 15, .code = "NotSupportedTxType" };
    pub const max_tx_size_exceeded = AcceptTxResult{ .id = 16, .code = "MaxTxSizeExceeded" };
    pub const not_current_nonce_for_delegation = AcceptTxResult{ .id = 17, .code = "NotCurrentNonceForDelegation" };
    pub const delegator_has_pending_tx = AcceptTxResult{ .id = 18, .code = "DelegatorHasPendingTx" };
    pub const syncing = AcceptTxResult{ .id = 503, .code = "Syncing" };

    /// Returns true only for the successful acceptance outcome.
    pub fn is_accepted(self: AcceptTxResult) bool {
        return self.id == accepted.id;
    }

    /// Returns a copy with an attached message.
    ///
    /// Empty messages are normalized to `null`.
    pub fn with_message(self: AcceptTxResult, message: []const u8) AcceptTxResult {
        return .{
            .id = self.id,
            .code = self.code,
            .message = if (message.len == 0) null else message,
        };
    }

    /// Equality by semantic outcome id (parity with Nethermind).
    pub fn eql(a: AcceptTxResult, b: AcceptTxResult) bool {
        return a.id == b.id;
    }

    /// Human-readable formatter: `<code>` or `<code>, <message>`.
    pub fn format(self: AcceptTxResult, writer: anytype) !void {
        if (self.message) |msg| {
            try writer.print("{s}, {s}", .{ self.code, msg });
            return;
        }
        try writer.writeAll(self.code);
    }
};

test "accept tx result: is_accepted only for accepted outcome" {
    try std.testing.expect(AcceptTxResult.accepted.is_accepted());
    try std.testing.expect(!AcceptTxResult.invalid.is_accepted());
    try std.testing.expect(!AcceptTxResult.syncing.is_accepted());
}

test "accept tx result: with_message attaches and normalizes message" {
    const with_msg = AcceptTxResult.fee_too_low.with_message("base fee too high");
    try std.testing.expectEqual(@as(?[]const u8, "base fee too high"), with_msg.message);
    try std.testing.expectEqual(AcceptTxResult.fee_too_low.id, with_msg.id);
    try std.testing.expectEqualStrings(AcceptTxResult.fee_too_low.code, with_msg.code);

    const no_msg = AcceptTxResult.fee_too_low.with_message("");
    try std.testing.expectEqual(@as(?[]const u8, null), no_msg.message);
}

test "accept tx result: eql compares id only" {
    const a = AcceptTxResult.nonce_gap;
    const b = AcceptTxResult.nonce_gap.with_message("future nonce");
    const c = AcceptTxResult.old_nonce;

    try std.testing.expect(AcceptTxResult.eql(a, b));
    try std.testing.expect(!AcceptTxResult.eql(a, c));
}

test "accept tx result: format matches code and code-with-message output" {
    var buf_plain: [64]u8 = undefined;
    const plain = try std.fmt.bufPrint(&buf_plain, "{f}", .{AcceptTxResult.invalid});
    try std.testing.expectEqualStrings("Invalid", plain);

    var buf_msg: [128]u8 = undefined;
    const with_msg = AcceptTxResult.invalid.with_message("bad rlp");
    const msg = try std.fmt.bufPrint(&buf_msg, "{f}", .{with_msg});
    try std.testing.expectEqualStrings("Invalid, bad rlp", msg);
}
