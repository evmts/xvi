const frame = @import("frame.zig");
const snappy_parameters = @import("snappy_parameters.zig");
const secrets_mod = @import("secrets.zig");
const mac_mod = @import("mac.zig");
const handshake_packet_mod = @import("handshake_packet.zig");

/// Snappy framing limits for RLPx compressed payloads.
pub const SnappyParameters = snappy_parameters;
/// Stable error set for Snappy pre-decompression metadata guards.
pub const SnappyGuardError = snappy_parameters.SnappyGuardError;
/// RLPx frame constants and padding helper.
pub const Frame = frame;
/// RLPx secrets derivation (shared/aes/mac) per spec.
pub const Secrets = secrets_mod.Secrets;
/// Derive handshake secrets; snake_case per Zig conventions.
pub const derive_secrets = secrets_mod.derive_secrets;

/// RLPx MAC state initialization (ingress/egress Keccak256 contexts).
pub const MacStates = mac_mod.MacStates;
/// Initialize default Keccak256-based MAC states per RLPx.
pub const init_mac_states = mac_mod.init_mac_states;
/// EIP-8 auth/ack size-prefixed packet validation helper.
pub const decode_eip8_size_prefixed_body = handshake_packet_mod.decode_eip8_size_prefixed_body;
/// Stable error set for EIP-8 size-prefixed packet decoding.
pub const HandshakePacketError = handshake_packet_mod.HandshakePacketError;
/// Minimal decoded EIP-8 auth-body values used by handshake key agreement.
pub const Eip8AuthBody = handshake_packet_mod.Eip8AuthBody;
/// Minimal decoded EIP-8 ack-body values used by handshake key agreement.
pub const Eip8AckBody = handshake_packet_mod.Eip8AckBody;
/// Stable error set for EIP-8 auth/ack RLP body decoding.
pub const HandshakeBodyDecodeError = handshake_packet_mod.HandshakeBodyDecodeError;
/// EIP-8 auth-body RLP decoder with forward-compatibility tolerance.
pub const decode_eip8_auth_body = handshake_packet_mod.decode_eip8_auth_body;
/// EIP-8 ack-body RLP decoder with forward-compatibility tolerance.
pub const decode_eip8_ack_body = handshake_packet_mod.decode_eip8_ack_body;
test {
    @import("std").testing.refAllDecls(@This());
}
