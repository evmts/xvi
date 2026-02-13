const std = @import("std");
// Voltaire primitives currently don't export SnappyParameters. Provide a tiny
// local shim until upstream exposes it.

/// Snappy compressed payload size limit for RLPx payloads.
/// Mirrors Nethermind's SnappyParameters.MaxSnappyLength.
pub const SnappyParameters = struct {
    pub const MaxSnappyLength: usize = 16 * 1024 * 1024;

    pub const ValidationError = error{
        MissingLengthHeader,
        LengthVarintTooLong,
        UncompressedLengthTooLarge,
        CompressedLengthTooLarge,
    };

    /// Parses the Snappy length preamble and enforces the RLPx 16 MiB cap.
    /// The preamble is a little-endian base-128 varint as per Snappy framing.
    pub fn validate_uncompressed_length(frame_data: []const u8) ValidationError!usize {
        if (frame_data.len > MaxSnappyLength) return error.CompressedLengthTooLarge;
        if (frame_data.len == 0) return error.MissingLengthHeader;

        var value: usize = 0;
        var shift: usize = 0;

        for (frame_data, 0..) |byte, idx| {
            if (idx >= 5) return error.LengthVarintTooLong;

            const chunk: usize = @as(usize, byte & 0x7f);
            const shifted = chunk << @as(std.math.Log2Int(usize), @intCast(shift));
            value = std.math.add(usize, value, shifted) catch return error.LengthVarintTooLong;

            if ((byte & 0x80) == 0) {
                if (value > MaxSnappyLength) return error.UncompressedLengthTooLarge;
                return value;
            }

            shift += 7;
        }

        return error.MissingLengthHeader;
    }

    /// Fast pre-decode guard for RLPx handlers before Snappy decompression.
    /// Returns the parsed uncompressed length so callers can size buffers.
    pub fn guard_before_decompression(frame_data: []const u8) ValidationError!usize {
        return validate_uncompressed_length(frame_data);
    }
};

test "snappy max length is 16 MiB" {
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), SnappyParameters.MaxSnappyLength);
}

test "validate_uncompressed_length parses snappy varint preamble" {
    try std.testing.expectEqual(@as(usize, 0), try SnappyParameters.validate_uncompressed_length(&[_]u8{0x00}));
    try std.testing.expectEqual(@as(usize, 1), try SnappyParameters.validate_uncompressed_length(&[_]u8{0x01}));
    try std.testing.expectEqual(
        SnappyParameters.MaxSnappyLength,
        try SnappyParameters.validate_uncompressed_length(&[_]u8{ 0x80, 0x80, 0x80, 0x08 }),
    );
}

test "validate_uncompressed_length rejects truncated preamble and long varint" {
    try std.testing.expectError(
        error.MissingLengthHeader,
        SnappyParameters.validate_uncompressed_length(&[_]u8{0x80}),
    );
    try std.testing.expectError(
        error.LengthVarintTooLong,
        SnappyParameters.validate_uncompressed_length(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }),
    );
}

test "validate_uncompressed_length enforces compressed and uncompressed limits" {
    try std.testing.expectError(
        error.UncompressedLengthTooLarge,
        SnappyParameters.validate_uncompressed_length(&[_]u8{ 0x81, 0x80, 0x80, 0x08 }),
    );

    const oversized = try std.testing.allocator.alloc(u8, SnappyParameters.MaxSnappyLength + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);

    try std.testing.expectError(
        error.CompressedLengthTooLarge,
        SnappyParameters.validate_uncompressed_length(oversized),
    );
}

test "guard_before_decompression accepts valid snappy preamble" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try SnappyParameters.guard_before_decompression(&[_]u8{0x01}),
    );
}

test "guard_before_decompression fails fast on oversized payload metadata" {
    try std.testing.expectError(
        error.UncompressedLengthTooLarge,
        SnappyParameters.guard_before_decompression(&[_]u8{ 0x81, 0x80, 0x80, 0x08 }),
    );
}
