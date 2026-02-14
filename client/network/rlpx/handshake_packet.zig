const std = @import("std");
const primitives = @import("primitives");

const Uint16 = primitives.Uint16;
const PrefixSize: usize = Uint16.SIZE;

/// Public, stable error set for EIP-8 size-prefixed handshake packets.
pub const HandshakePacketError = error{
    MissingSizePrefix,
    EmptyCiphertextBody,
    InvalidPacketLength,
};

/// Validates and decodes an EIP-8 handshake packet payload.
///
/// Packet format (both auth and ack):
/// `packet = size(2-byte be) || enc-body`, where `size == enc-body.len`.
pub fn decode_eip8_size_prefixed_body(packet: []const u8) HandshakePacketError![]const u8 {
    if (packet.len < PrefixSize) return error.MissingSizePrefix;

    const size_field = Uint16.fromBytes(packet[0..PrefixSize]) orelse return error.MissingSizePrefix;
    const encrypted_body_size: usize = size_field.toNumber();
    if (encrypted_body_size == 0) return error.EmptyCiphertextBody;

    const expected_total_size = PrefixSize + encrypted_body_size;
    if (packet.len != expected_total_size) return error.InvalidPacketLength;

    return packet[PrefixSize..expected_total_size];
}

test "decode_eip8_size_prefixed_body decodes valid packet body" {
    const packet = [_]u8{ 0x00, 0x03, 0xAA, 0xBB, 0xCC };
    const body = try decode_eip8_size_prefixed_body(&packet);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, body);
}

test "decode_eip8_size_prefixed_body rejects packet without full size prefix" {
    try std.testing.expectError(
        error.MissingSizePrefix,
        decode_eip8_size_prefixed_body(&[_]u8{0x00}),
    );
}

test "decode_eip8_size_prefixed_body rejects zero-length encrypted body" {
    try std.testing.expectError(
        error.EmptyCiphertextBody,
        decode_eip8_size_prefixed_body(&[_]u8{ 0x00, 0x00 }),
    );
}

test "decode_eip8_size_prefixed_body rejects truncated packet" {
    try std.testing.expectError(
        error.InvalidPacketLength,
        decode_eip8_size_prefixed_body(&[_]u8{ 0x00, 0x03, 0xAA, 0xBB }),
    );
}

test "decode_eip8_size_prefixed_body rejects packet with trailing bytes" {
    try std.testing.expectError(
        error.InvalidPacketLength,
        decode_eip8_size_prefixed_body(&[_]u8{ 0x00, 0x03, 0xAA, 0xBB, 0xCC, 0xDD }),
    );
}
