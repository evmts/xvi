/// Chain management entry point for the client.
const chain = @import("chain.zig");
const validator = @import("validator.zig");
const blockchain = @import("blockchain");

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
/// Canonical head number lookup helper.
pub const head_number = chain.head_number;
/// Canonicality checks.
pub const is_canonical = chain.is_canonical;
/// Canonicality check that may use fork-cache backed fetches.
pub const is_canonical_or_fetch = chain.is_canonical_or_fetch;
/// Existence check (local or fork-cache).
pub const has_block = chain.has_block;
/// Local-only block lookup (no fork-cache fetch/allocations).
pub const get_block_local = chain.get_block_local; // implemented via local_access adapter
/// Local-only canonical block lookup by number (no fork-cache fetch/allocations).
pub const get_block_by_number_local = chain.get_block_by_number_local; // via local_access
/// Local-only parent block lookup (no fork-cache fetch/allocations).
pub const get_parent_block_local = chain.get_parent_block_local;
/// Local-only parent header lookup returning typed ValidationError.
pub const parent_header_local = chain.parent_header_local;
/// Canonical hash lookup by number (local-only read).
pub const canonical_hash = chain.canonical_hash;
/// Canonical head update helper (local-only mutation).
pub const set_canonical_head = chain.set_canonical_head;
/// Local-only BLOCKHASH-style lookup by block number.
pub const block_hash_by_number_local = chain.block_hash_by_number_local;
/// Local-only collection of up-to-256 recent block hashes (spec order).
pub const last_256_block_hashes_local = chain.last_256_block_hashes_local;
/// Local-only lowest common ancestor hash lookup between two blocks.
pub const common_ancestor_hash_local = chain.common_ancestor_hash_local;
/// Local-only canonical divergence check between current head and candidate head.
pub const has_canonical_divergence_local = chain.has_canonical_divergence_local;
/// Local-only reorg depth from canonical head to candidate common ancestor.
pub const canonical_reorg_depth_local = chain.canonical_reorg_depth_local;
/// Local-only candidate-branch depth from candidate head to candidate common ancestor.
pub const candidate_reorg_depth_local = chain.candidate_reorg_depth_local;
/// Generic comptime DI helpers for head reads.
pub const head_hash_of = chain.head_hash_of;
/// Generic comptime DI helper for head block reads.
pub const head_block_of = chain.head_block_of;
/// Generic comptime DI helper for head block reads with retry policy.
pub const head_block_of_with_policy = chain.head_block_of_with_policy;
/// Generic comptime DI helper for head number reads.
pub const head_number_of = chain.head_number_of;
/// Safe/finalized head helpers (local-only).
pub const safe_head_hash_of = chain.safe_head_hash_of;
/// Local-only finalized head hash helper.
pub const finalized_head_hash_of = chain.finalized_head_hash_of;
/// Local-only safe head block helper.
pub const safe_head_block_of = chain.safe_head_block_of;
/// Local-only finalized head block helper.
pub const finalized_head_block_of = chain.finalized_head_block_of;
/// Shared header validation errors.
pub const ValidationError = validator.ValidationError;
/// Header validation context.
pub const HeaderValidationContext = validator.HeaderValidationContext;
/// Merge-aware header validator.
pub const merge_header_validator = validator.merge_header_validator;

test {
    @import("std").testing.refAllDecls(@This());
}
