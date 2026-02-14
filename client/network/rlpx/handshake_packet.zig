const std = @import("std");
const primitives = @import("primitives");

const Uint16 = primitives.Uint16;
const Rlp = primitives.Rlp;
const Signature = primitives.Signature;
const PublicKey = primitives.PublicKey.PublicKey;
const Bytes32 = primitives.Bytes32.Bytes32;
const PrefixSize: usize = Uint16.SIZE;
const NonceSize: usize = primitives.Bytes32.SIZE;
const PublicKeySize: usize = 64;
const SignatureSize: usize = 65;
const DecodeScratchSize: usize = 1024;

/// Public, stable error set for EIP-8 size-prefixed handshake packets.
pub const HandshakePacketError = error{
    MissingSizePrefix,
    EmptyCiphertextBody,
    InvalidPacketLength,
};

/// Public, stable error set for EIP-8 auth/ack RLP body decoding.
pub const HandshakeBodyDecodeError = error{
    InvalidRlpBody,
    MissingRequiredField,
    InvalidSignatureLength,
    InvalidPublicKeyLength,
    InvalidNonceLength,
};

/// Minimal decoded `auth-body` values required by the RLPx handshake.
pub const Eip8AuthBody = struct {
    signature: Signature,
    initiator_public_key: PublicKey,
    initiator_nonce: Bytes32,
};

/// Minimal decoded `ack-body` values required by the RLPx handshake.
pub const Eip8AckBody = struct {
    recipient_ephemeral_public_key: PublicKey,
    recipient_nonce: Bytes32,
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

/// Decodes an EIP-8 `auth-body` from decrypted plaintext.
///
/// EIP-8 forward-compatibility rules applied here:
/// - `auth-vsn` value is intentionally ignored (version mismatches tolerated)
/// - extra list elements are ignored
/// - trailing bytes after the top-level list are ignored
pub fn decode_eip8_auth_body(body: []const u8) HandshakeBodyDecodeError!Eip8AuthBody {
    var scratch: [DecodeScratchSize]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const decoded = Rlp.decode(fba.allocator(), body, true) catch return error.InvalidRlpBody;
    defer decoded.data.deinit(fba.allocator());

    const items = switch (decoded.data) {
        .List => |list| list,
        else => return error.InvalidRlpBody,
    };
    if (items.len < 3) return error.MissingRequiredField;

    const signature_bytes = try read_rlp_bytes_exact(items[0], SignatureSize, error.InvalidSignatureLength);
    const initiator_public_key_bytes = try read_rlp_bytes_exact(items[1], PublicKeySize, error.InvalidPublicKeyLength);
    const initiator_nonce_bytes = try read_rlp_bytes_exact(items[2], NonceSize, error.InvalidNonceLength);

    var signature_r: [32]u8 = undefined;
    var signature_s: [32]u8 = undefined;
    @memcpy(&signature_r, signature_bytes[0..32]);
    @memcpy(&signature_s, signature_bytes[32..64]);
    const signature = Signature.fromSecp256k1(signature_r, signature_s, signature_bytes[64]);

    var initiator_public_key = PublicKey{ .bytes = undefined };
    @memcpy(&initiator_public_key.bytes, initiator_public_key_bytes);

    return .{
        .signature = signature,
        .initiator_public_key = initiator_public_key,
        .initiator_nonce = primitives.Bytes32.fromBytes(initiator_nonce_bytes),
    };
}

/// Decodes an EIP-8 `ack-body` from decrypted plaintext.
///
/// EIP-8 forward-compatibility rules applied here:
/// - `ack-vsn` value is intentionally ignored (version mismatches tolerated)
/// - extra list elements are ignored
/// - trailing bytes after the top-level list are ignored
pub fn decode_eip8_ack_body(body: []const u8) HandshakeBodyDecodeError!Eip8AckBody {
    var scratch: [DecodeScratchSize]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const decoded = Rlp.decode(fba.allocator(), body, true) catch return error.InvalidRlpBody;
    defer decoded.data.deinit(fba.allocator());

    const items = switch (decoded.data) {
        .List => |list| list,
        else => return error.InvalidRlpBody,
    };
    if (items.len < 2) return error.MissingRequiredField;

    const recipient_ephemeral_public_key_bytes = try read_rlp_bytes_exact(items[0], PublicKeySize, error.InvalidPublicKeyLength);
    const recipient_nonce_bytes = try read_rlp_bytes_exact(items[1], NonceSize, error.InvalidNonceLength);

    var recipient_ephemeral_public_key = PublicKey{ .bytes = undefined };
    @memcpy(&recipient_ephemeral_public_key.bytes, recipient_ephemeral_public_key_bytes);

    return .{
        .recipient_ephemeral_public_key = recipient_ephemeral_public_key,
        .recipient_nonce = primitives.Bytes32.fromBytes(recipient_nonce_bytes),
    };
}

fn read_rlp_bytes_exact(
    item: Rlp.Data,
    expected_len: usize,
    length_error: HandshakeBodyDecodeError,
) HandshakeBodyDecodeError![]const u8 {
    const bytes = switch (item) {
        .String => |value| value,
        else => return error.InvalidRlpBody,
    };
    if (bytes.len != expected_len) return length_error;
    return bytes;
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

test "decode_eip8_auth_body tolerates version mismatch, extra elements, and trailing bytes" {
    var signature: [SignatureSize]u8 = undefined;
    for (&signature, 0..) |*byte, i| byte.* = @as(u8, @intCast(i));

    var initiator_public_key: [PublicKeySize]u8 = undefined;
    for (&initiator_public_key, 0..) |*byte, i| byte.* = @as(u8, @intCast(i + 1));

    var initiator_nonce: [NonceSize]u8 = undefined;
    for (&initiator_nonce, 0..) |*byte, i| byte.* = @as(u8, @intCast(i + 2));

    const encoded = try Rlp.encode(std.testing.allocator, [_][]const u8{
        signature[0..],
        initiator_public_key[0..],
        initiator_nonce[0..],
        &[_]u8{0x99}, // mismatched auth-vsn (ignored)
        &[_]u8{ 0xDE, 0xAD }, // extra list element (ignored)
    });
    defer std.testing.allocator.free(encoded);

    const encoded_with_trailing = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ encoded, &[_]u8{ 0xFA, 0xCE } },
    );
    defer std.testing.allocator.free(encoded_with_trailing);

    const decoded = try decode_eip8_auth_body(encoded_with_trailing);
    try std.testing.expectEqualSlices(u8, signature[0..32], &decoded.signature.r);
    try std.testing.expectEqualSlices(u8, signature[32..64], &decoded.signature.s);
    try std.testing.expectEqual(@as(?u8, signature[64]), decoded.signature.v);
    try std.testing.expectEqual(.secp256k1, decoded.signature.algorithm);
    try std.testing.expectEqualSlices(u8, &initiator_public_key, &decoded.initiator_public_key.bytes);
    try std.testing.expectEqualSlices(u8, &initiator_nonce, &decoded.initiator_nonce);
}

test "decode_eip8_auth_body rejects missing required nonce field" {
    const signature = [_]u8{0xAA} ** SignatureSize;
    const initiator_public_key = [_]u8{0xBB} ** PublicKeySize;
    const encoded = try Rlp.encode(std.testing.allocator, [_][]const u8{
        &signature,
        &initiator_public_key,
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.MissingRequiredField, decode_eip8_auth_body(encoded));
}

test "decode_eip8_auth_body rejects invalid signature length" {
    const short_signature = [_]u8{0xAA} ** (SignatureSize - 1);
    const initiator_public_key = [_]u8{0xBB} ** PublicKeySize;
    const initiator_nonce = [_]u8{0xCC} ** NonceSize;
    const encoded = try Rlp.encode(std.testing.allocator, [_][]const u8{
        &short_signature,
        &initiator_public_key,
        &initiator_nonce,
        &[_]u8{0x04},
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.InvalidSignatureLength, decode_eip8_auth_body(encoded));
}

test "decode_eip8_ack_body tolerates version mismatch, extra elements, and trailing bytes" {
    var recipient_ephemeral_public_key: [PublicKeySize]u8 = undefined;
    for (&recipient_ephemeral_public_key, 0..) |*byte, i| byte.* = @as(u8, @intCast(i + 3));

    var recipient_nonce: [NonceSize]u8 = undefined;
    for (&recipient_nonce, 0..) |*byte, i| byte.* = @as(u8, @intCast(i + 4));

    const encoded = try Rlp.encode(std.testing.allocator, [_][]const u8{
        recipient_ephemeral_public_key[0..],
        recipient_nonce[0..],
        &[_]u8{0x01}, // mismatched ack-vsn (ignored)
        &[_]u8{0xEF}, // extra list element (ignored)
    });
    defer std.testing.allocator.free(encoded);

    const encoded_with_trailing = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ encoded, &[_]u8{ 0xBA, 0xBE } },
    );
    defer std.testing.allocator.free(encoded_with_trailing);

    const decoded = try decode_eip8_ack_body(encoded_with_trailing);
    try std.testing.expectEqualSlices(u8, &recipient_ephemeral_public_key, &decoded.recipient_ephemeral_public_key.bytes);
    try std.testing.expectEqualSlices(u8, &recipient_nonce, &decoded.recipient_nonce);
}

test "decode_eip8_ack_body rejects missing nonce field" {
    const recipient_ephemeral_public_key = [_]u8{0xDD} ** PublicKeySize;
    const encoded = try Rlp.encode(std.testing.allocator, [_][]const u8{
        &recipient_ephemeral_public_key,
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.MissingRequiredField, decode_eip8_ack_body(encoded));
}

test "decode_eip8_ack_body rejects invalid public key length" {
    const short_public_key = [_]u8{0xDD} ** (PublicKeySize - 1);
    const recipient_nonce = [_]u8{0xEE} ** NonceSize;
    const encoded = try Rlp.encode(std.testing.allocator, [_][]const u8{
        &short_public_key,
        &recipient_nonce,
        &[_]u8{0x04},
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.InvalidPublicKeyLength, decode_eip8_ack_body(encoded));
}
