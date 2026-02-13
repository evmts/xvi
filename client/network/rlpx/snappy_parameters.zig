const std = @import("std");
const primitives = @import("primitives");
const frame = @import("frame.zig");
const Uint32 = primitives.Uint32;

/// Snappy compressed payload size limit for RLPx payloads.
/// Mirrors Nethermind's SnappyParameters.MaxSnappyLength.
pub const MaxSnappyLength: usize = 16 * 1024 * 1024;

// Snappy length headers are varints of an unsigned 32-bit value.
const MaxLengthVarintBytes: usize = (Uint32.BITS + 6) / 7;

/// Parses the Snappy length preamble and enforces the RLPx 16 MiB cap.
/// The preamble is a little-endian base-128 varint as per Snappy framing.
pub fn validate_uncompressed_length(frame_data: []const u8) error{
    MissingLengthHeader,
    LengthVarintTooLong,
    UncompressedLengthTooLarge,
    CompressedLengthTooLarge,
}!usize {
    if (frame_data.len > @as(usize, @intCast(frame.ProtocolMaxFrameSize))) return error.CompressedLengthTooLarge;
    if (frame_data.len == 0) return error.MissingLengthHeader;

    var value: usize = 0;
    var shift: usize = 0;

    for (frame_data, 0..) |byte, idx| {
        if (idx >= MaxLengthVarintBytes) return error.LengthVarintTooLong;

        const chunk: usize = @as(usize, byte & 0x7f);
        const shifted = chunk << @as(std.math.Log2Int(usize), @intCast(shift));
        value = std.math.add(usize, value, shifted) catch return error.LengthVarintTooLong;

        if ((byte & 0x80) == 0) {
            if (value > MaxSnappyLength) return error.UncompressedLengthTooLarge;
            return value;
        }

        if (idx + 1 == MaxLengthVarintBytes) return error.LengthVarintTooLong;
        shift += 7;
    }

    return error.MissingLengthHeader;
}

/// Fast pre-decode guard for RLPx handlers before Snappy decompression.
/// Returns the parsed uncompressed length so callers can size buffers.
pub fn guard_before_decompression(frame_data: []const u8) error{
    MissingLengthHeader,
    LengthVarintTooLong,
    UncompressedLengthTooLarge,
    CompressedLengthTooLarge,
}!usize {
    return validate_uncompressed_length(frame_data);
}

test "snappy max length is 16 MiB" {
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), MaxSnappyLength);
}

test "validate_uncompressed_length parses snappy varint preamble" {
    try std.testing.expectEqual(@as(usize, 0), try validate_uncompressed_length(&[_]u8{0x00}));
    try std.testing.expectEqual(@as(usize, 1), try validate_uncompressed_length(&[_]u8{0x01}));
    try std.testing.expectEqual(
        MaxSnappyLength,
        try validate_uncompressed_length(&[_]u8{ 0x80, 0x80, 0x80, 0x08 }),
    );
}

test "validate_uncompressed_length rejects truncated preamble and long varint" {
    try std.testing.expectError(
        error.MissingLengthHeader,
        validate_uncompressed_length(&[_]u8{0x80}),
    );
    try std.testing.expectError(
        error.LengthVarintTooLong,
        validate_uncompressed_length(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80 }),
    );
    try std.testing.expectError(
        error.LengthVarintTooLong,
        validate_uncompressed_length(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }),
    );
}

test "validate_uncompressed_length enforces compressed and uncompressed limits" {
    try std.testing.expectError(
        error.UncompressedLengthTooLarge,
        validate_uncompressed_length(&[_]u8{ 0x81, 0x80, 0x80, 0x08 }),
    );

    const max_compressed = @as(usize, @intCast(frame.ProtocolMaxFrameSize));
    const at_limit = try std.testing.allocator.alloc(u8, max_compressed);
    defer std.testing.allocator.free(at_limit);
    @memset(at_limit, 0);
    try std.testing.expectEqual(@as(usize, 0), try validate_uncompressed_length(at_limit));

    const oversized = try std.testing.allocator.alloc(u8, @as(usize, @intCast(frame.ProtocolMaxFrameSize)) + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);

    try std.testing.expectError(
        error.CompressedLengthTooLarge,
        validate_uncompressed_length(oversized),
    );
}

test "guard_before_decompression accepts valid snappy preamble" {
    try std.testing.expectEqual(
        @as(usize, 1),
        try guard_before_decompression(&[_]u8{0x01}),
    );
}

test "guard_before_decompression fails fast on oversized payload metadata" {
    try std.testing.expectError(
        error.UncompressedLengthTooLarge,
        guard_before_decompression(&[_]u8{ 0x81, 0x80, 0x80, 0x08 }),
    );
}

test "guard_before_decompression rejects continuation-only five-byte varint" {
    try std.testing.expectError(
        error.LengthVarintTooLong,
        guard_before_decompression(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80 }),
    );
}
