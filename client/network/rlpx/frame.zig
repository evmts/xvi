const std = @import("std");
const Rlp = @import("primitives").Rlp;

/// Size of the RLPx MAC (16 bytes).
pub const MacSize: u16 = 16;
/// Size of the encrypted RLPx header (16 bytes).
pub const HeaderSize: u16 = 16;
/// AES-CTR block size used for header/data padding (16 bytes).
pub const BlockSize: u16 = 16;
/// Maximum frame-size representable by the 24-bit RLPx header.
pub const ProtocolMaxFrameSize: u24 = 0xFF_FF_FF;
/// Default fragmentation target for outbound frames; not a hard inbound limit.
pub const DefaultMaxFrameSize: u16 = BlockSize * 64;
/// Public, stable error set for frame helpers to avoid error-set widening.
pub const FrameError = error{
    InvalidFrameSize,
};
/// Public, stable error set for frame-header packet length validation.
pub const FrameHeaderError = error{
    InvalidTotalPacketSize,
    FrameSizeExceedsTotalPacketSize,
};
/// Public, stable error set for frame-header extension decoding.
pub const FrameHeaderDecodeError = FrameHeaderError || error{
    InvalidHeaderData,
};

/// Decoded and validated frame-header metadata.
pub const FrameHeaderMetadata = struct {
    is_chunked: bool,
    is_first_chunk: bool,
    frame_size: usize,
    total_packet_size: usize,
    context_id: ?usize,
};

/// Returns the zero-fill padding required to align to the AES block size.
pub inline fn calculate_padding(size: usize) usize {
    const remainder = size % BlockSize;
    return if (remainder == 0) 0 else BlockSize - remainder;
}

/// Encodes a frame size as a 24-bit big-endian integer for the RLPx header.
/// Errors when `size` exceeds the protocol's 24-bit representable limit.
pub inline fn encode_frame_size_24(size: usize) FrameError![3]u8 {
    if (size > ProtocolMaxFrameSize) return FrameError.InvalidFrameSize;
    var out: [3]u8 = undefined;
    // Use std.mem primitives for well-defined u24 big-endian encoding.
    std.mem.writeInt(u24, &out, @as(u24, @intCast(size)), .big);
    return out;
}

/// Decodes a 24-bit big-endian frame size from the RLPx header bytes.
/// The input must be exactly three bytes as per RLPx framing.
pub inline fn decode_frame_size_24(bytes: [3]u8) usize {
    const v: u24 = std.mem.readInt(u24, &bytes, .big);
    return @as(usize, @intCast(v));
}

/// Validates optional total packet size from frame header extension data.
///
/// - `total_packet_size = null` is valid for non-chunked frames.
/// - When present, `total_packet_size` must be in `1..=max_packet_size`.
/// - `frame_size` cannot exceed `total_packet_size`.
pub inline fn validate_total_packet_size(
    frame_size: usize,
    total_packet_size: ?usize,
    max_packet_size: usize,
) FrameHeaderError!void {
    if (total_packet_size) |total| {
        if (total == 0 or total > max_packet_size) return error.InvalidTotalPacketSize;
        if (frame_size > total) return error.FrameSizeExceedsTotalPacketSize;
    }
}

/// Decode header-data extension fields from decrypted RLPx header bytes.
///
/// `header_data_with_padding` is the 13-byte header-data region:
/// `header[3..16] = rlp([capability-id, context-id, total-packet-size?]) || zero-padding`.
/// Trailing bytes after the RLP list are ignored as padding.
pub fn decode_header_extensions(
    frame_size: usize,
    header_data_with_padding: []const u8,
    max_packet_size: usize,
) FrameHeaderDecodeError!FrameHeaderMetadata {
    // Use Voltaire's canonical RLP decoder to parse list bounds/items and reject malformed
    // encodings (e.g. non-minimal long-form lengths or leading-zero length-of-length).
    var rlp_scratch: [512]u8 = undefined;
    var rlp_fba = std.heap.FixedBufferAllocator.init(&rlp_scratch);
    const rlp_decoded = Rlp.decode(rlp_fba.allocator(), header_data_with_padding, true) catch {
        return error.InvalidHeaderData;
    };
    defer rlp_decoded.data.deinit(rlp_fba.allocator());

    const list_items = switch (rlp_decoded.data) {
        .List => |items| items,
        else => return error.InvalidHeaderData,
    };
    if (list_items.len == 0 or list_items.len > 3) return error.InvalidHeaderData;

    // capability-id is currently always zero in RLPx, but parsed for forward compatibility.
    _ = try decode_rlp_uint(list_items[0]);

    var context_id: ?usize = null;
    var total_packet_size: ?usize = null;

    if (list_items.len > 1) {
        context_id = try decode_rlp_uint(list_items[1]);
    }

    if (list_items.len > 2) {
        total_packet_size = try decode_rlp_uint(list_items[2]);
    }

    try validate_total_packet_size(frame_size, total_packet_size, max_packet_size);

    const is_chunked = total_packet_size != null or (context_id != null and context_id.? != 0);
    const is_first_chunk = total_packet_size != null or !is_chunked;

    return .{
        .is_chunked = is_chunked,
        .is_first_chunk = is_first_chunk,
        .frame_size = frame_size,
        .total_packet_size = total_packet_size orelse frame_size,
        .context_id = context_id,
    };
}

fn decode_rlp_uint(item: Rlp.Data) FrameHeaderDecodeError!usize {
    const bytes = switch (item) {
        .String => |str| str,
        else => return error.InvalidHeaderData,
    };
    if (bytes.len == 0) return 0;
    if (bytes.len == 1) return @as(usize, bytes[0]);
    return parse_big_endian_usize(bytes);
}

fn parse_big_endian_usize(bytes: []const u8) FrameHeaderDecodeError!usize {
    if (bytes.len == 0) return error.InvalidHeaderData;
    var value: usize = 0;
    for (bytes) |byte| {
        const shifted = std.math.mul(usize, value, 256) catch return error.InvalidHeaderData;
        value = std.math.add(usize, shifted, @as(usize, byte)) catch return error.InvalidHeaderData;
    }
    return value;
}

test "calculate padding returns zero for aligned sizes" {
    try std.testing.expectEqual(@as(usize, 0), calculate_padding(0));
    try std.testing.expectEqual(@as(usize, 0), calculate_padding(BlockSize));
    try std.testing.expectEqual(@as(usize, 0), calculate_padding(BlockSize * 4));
}

test "calculate padding returns remainder to block size" {
    try std.testing.expectEqual(@as(usize, 15), calculate_padding(1));
    try std.testing.expectEqual(@as(usize, 1), calculate_padding(BlockSize - 1));
    try std.testing.expectEqual(@as(usize, 8), calculate_padding(BlockSize * 2 + 8));
}

test "frame constants mirror Nethermind defaults and protocol limits" {
    try std.testing.expectEqual(@as(u16, 16), MacSize);
    try std.testing.expectEqual(@as(u16, 16), HeaderSize);
    try std.testing.expectEqual(@as(u16, 16), BlockSize);
    try std.testing.expectEqual(@as(u16, 1024), DefaultMaxFrameSize);
    try std.testing.expectEqual(@as(u24, 0xFF_FF_FF), ProtocolMaxFrameSize);
}

test "encode_frame_size_24: encodes boundaries" {
    const zero = try encode_frame_size_24(0);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00 }, &zero);

    const one = try encode_frame_size_24(1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x01 }, &one);

    const max = try encode_frame_size_24(ProtocolMaxFrameSize);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF }, &max);
}

test "encode_frame_size_24: rejects values > 24-bit" {
    const too_big: usize = @as(usize, @intCast(ProtocolMaxFrameSize)) + 1;
    try std.testing.expectError(FrameError.InvalidFrameSize, encode_frame_size_24(too_big));
}

test "decode_frame_size_24: decodes boundaries" {
    try std.testing.expectEqual(@as(usize, 0), decode_frame_size_24(.{ 0x00, 0x00, 0x00 }));
    try std.testing.expectEqual(@as(usize, 1), decode_frame_size_24(.{ 0x00, 0x00, 0x01 }));
    try std.testing.expectEqual(ProtocolMaxFrameSize, decode_frame_size_24(.{ 0xFF, 0xFF, 0xFF }));
}

test "decode_frame_size_24: roundtrips representative values" {
    const values = [_]usize{ 0, 1, 15, 16, 255, 256, 1024, 4096, 65535, 70000, 1_000_000, ProtocolMaxFrameSize };
    inline for (values) |v| {
        const enc = try encode_frame_size_24(v);
        const dec = decode_frame_size_24(enc);
        try std.testing.expectEqual(v, dec);
    }
}

test "validate_total_packet_size: accepts null for non-chunked frame" {
    try validate_total_packet_size(1024, null, 16 * 1024 * 1024);
}

test "validate_total_packet_size: accepts valid bounded totals" {
    try validate_total_packet_size(1, 1, 16 * 1024 * 1024);
    try validate_total_packet_size(1024, 4096, 16 * 1024 * 1024);
    try validate_total_packet_size(16 * 1024 * 1024, 16 * 1024 * 1024, 16 * 1024 * 1024);
}

test "validate_total_packet_size: rejects zero total size" {
    try std.testing.expectError(
        error.InvalidTotalPacketSize,
        validate_total_packet_size(1, 0, 16 * 1024 * 1024),
    );
}

test "validate_total_packet_size: rejects totals above max bound" {
    try std.testing.expectError(
        error.InvalidTotalPacketSize,
        validate_total_packet_size(1, (16 * 1024 * 1024) + 1, 16 * 1024 * 1024),
    );
}

test "validate_total_packet_size: rejects frame larger than declared total" {
    try std.testing.expectError(
        error.FrameSizeExceedsTotalPacketSize,
        validate_total_packet_size(1025, 1024, 16 * 1024 * 1024),
    );
}

test "decode_header_extensions: decodes non-chunked header data" {
    const header_data = [_]u8{ 0xC2, 0x80, 0x80 } ++ [_]u8{0} ** 10;
    const decoded = try decode_header_extensions(1024, &header_data, 16 * 1024 * 1024);

    try std.testing.expect(!decoded.is_chunked);
    try std.testing.expect(decoded.is_first_chunk);
    try std.testing.expectEqual(@as(usize, 1024), decoded.frame_size);
    try std.testing.expectEqual(@as(usize, 1024), decoded.total_packet_size);
    try std.testing.expectEqual(@as(?usize, 0), decoded.context_id);
}

test "decode_header_extensions: decodes first chunk metadata with total packet size" {
    const header_data = [_]u8{ 0xC5, 0x80, 0x07, 0x82, 0x03, 0xE8 } ++ [_]u8{0} ** 7;
    const decoded = try decode_header_extensions(256, &header_data, 16 * 1024 * 1024);

    try std.testing.expect(decoded.is_chunked);
    try std.testing.expect(decoded.is_first_chunk);
    try std.testing.expectEqual(@as(usize, 256), decoded.frame_size);
    try std.testing.expectEqual(@as(usize, 1000), decoded.total_packet_size);
    try std.testing.expectEqual(@as(?usize, 7), decoded.context_id);
}

test "decode_header_extensions: decodes continuation chunk metadata without total packet size" {
    const header_data = [_]u8{ 0xC2, 0x80, 0x07 } ++ [_]u8{0} ** 10;
    const decoded = try decode_header_extensions(512, &header_data, 16 * 1024 * 1024);

    try std.testing.expect(decoded.is_chunked);
    try std.testing.expect(!decoded.is_first_chunk);
    try std.testing.expectEqual(@as(usize, 512), decoded.frame_size);
    try std.testing.expectEqual(@as(usize, 512), decoded.total_packet_size);
    try std.testing.expectEqual(@as(?usize, 7), decoded.context_id);
}

test "decode_header_extensions: rejects invalid header data and extra extension elements" {
    const non_list = [_]u8{0x80} ++ [_]u8{0} ** 12;
    try std.testing.expectError(
        error.InvalidHeaderData,
        decode_header_extensions(32, &non_list, 16 * 1024 * 1024),
    );

    const extra_item = [_]u8{ 0xC4, 0x80, 0x01, 0x80, 0x02 } ++ [_]u8{0} ** 8;
    try std.testing.expectError(
        error.InvalidHeaderData,
        decode_header_extensions(32, &extra_item, 16 * 1024 * 1024),
    );
}

test "decode_header_extensions: propagates total packet size validation errors" {
    const zero_total = [_]u8{ 0xC3, 0x80, 0x01, 0x80 } ++ [_]u8{0} ** 9;
    try std.testing.expectError(
        error.InvalidTotalPacketSize,
        decode_header_extensions(32, &zero_total, 16 * 1024 * 1024),
    );

    const frame_exceeds_total = [_]u8{ 0xC3, 0x80, 0x01, 0x20 } ++ [_]u8{0} ** 9;
    try std.testing.expectError(
        error.FrameSizeExceedsTotalPacketSize,
        decode_header_extensions(33, &frame_exceeds_total, 16 * 1024 * 1024),
    );

    const total_exceeds_max = [_]u8{ 0xC7, 0x80, 0x01, 0x84, 0x01, 0x00, 0x00, 0x01 } ++ [_]u8{0} ** 5;
    try std.testing.expectError(
        error.InvalidTotalPacketSize,
        decode_header_extensions(1, &total_exceeds_max, 16 * 1024 * 1024),
    );
}
