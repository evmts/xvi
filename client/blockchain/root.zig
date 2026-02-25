/// Chain management entry point for the client.
const std = @import("std");
const chain = @import("chain.zig");
const validator = @import("validator.zig");
const blockchain = @import("blockchain");
const primitives = @import("voltaire");
const Block = primitives.Block;
const BlockHeader = primitives.BlockHeader;
const BlockBody = primitives.BlockBody;
const Hash = primitives.Hash;

// -- Public API --------------------------------------------------------------

/// Chain management API rooted in Voltaire's `Blockchain` primitive.
///
/// All public aliases exposed here intentionally re-export Voltaire primitives
/// or thin helpers around them; no custom types are introduced at this layer.
pub const Chain = chain.Chain;
/// Direct re-exports for consumers needing raw Voltaire types.
pub const Blockchain = blockchain.Blockchain;
/// Re-export of Voltaire fork-cache primitive for remote block lookups.
pub const ForkBlockCache = blockchain.ForkBlockCache;
/// Canonical head helpers.
pub const head_hash = chain.head_hash;
/// Canonical head block lookup helper.
pub const head_block = chain.head_block;
/// Pending hash helper (defaults to canonical head hash, local-only).
pub const pending_hash = chain.pending_hash;
/// Pending block helper (finder-style resolution from pending hash).
pub const pending_block = chain.pending_block;
/// Shared header validation errors.
pub const ValidationError = validator.ValidationError;
/// Header validation context.
pub const HeaderValidationContext = validator.HeaderValidationContext;
/// Merge-aware header validator.
pub const merge_header_validator = validator.merge_header_validator;

test {
    std.testing.refAllDecls(@This());
}

test "root exports - head and pending helpers behave consistently" {
    var chain_state = try Chain.init(std.testing.allocator, null);
    defer chain_state.deinit();

    const genesis = try Block.genesis(1, std.testing.allocator);
    try chain_state.putBlock(genesis);
    try chain_state.setCanonicalHead(genesis.hash);

    try std.testing.expectEqual(@as(u64, 0), chain_state.getHeadBlockNumber() orelse return error.UnexpectedNull);

    const hh = (try head_hash(&chain_state)) orelse return error.UnexpectedNull;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hh);

    const ph = pending_hash(&chain_state) orelse return error.UnexpectedNull;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &ph);

    const pb = (try pending_block(&chain_state)) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(u64, 0), pb.header.number);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &pb.hash);
}
