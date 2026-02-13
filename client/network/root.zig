/// devp2p networking surface for the Guillotine execution client.
const std = @import("std");

const rlpx = @import("rlpx/root.zig");

/// Snappy framing limits for RLPx compressed payloads.
pub const SnappyParameters = rlpx.SnappyParameters;
/// RLPx frame constants and padding helper.
pub const Frame = rlpx.Frame;

/// Validates inbound compressed DEVp2p payload metadata before decompression.
pub fn guard_inbound_snappy_payload(frame_data: []const u8) rlpx.SnappyParameters.ValidationError!usize {
    return rlpx.SnappyParameters.guard_before_decompression(frame_data);
}

test "guard_inbound_snappy_payload forwards valid preamble lengths" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try guard_inbound_snappy_payload(&[_]u8{0x01}),
    );
}

test "guard_inbound_snappy_payload rejects oversized uncompressed metadata" {
    try std.testing.expectError(
        error.UncompressedLengthTooLarge,
        guard_inbound_snappy_payload(&[_]u8{ 0x81, 0x80, 0x80, 0x08 }),
    );
}

test {
    std.testing.refAllDecls(@This());
}
