//! Merkle Patricia Trie module for the Guillotine execution client.
//!
//! Implements the Modified Merkle Patricia Trie (MPT) for Ethereum state
//! storage, matching the authoritative Python execution-specs behavior.
//!
//! ## Modules
//!
//! - `hash` — Root hash computation via `patricialize()` algorithm
//!
//! ## Architecture
//!
//! The trie module implements the spec's `patricialize()` approach: given a
//! flat key-value mapping, it recursively builds the MPT and computes the
//! root hash. This matches `execution-specs/src/ethereum/forks/frontier/trie.py`
//! exactly, including the < 32-byte node inlining rule.
//!
//! Voltaire primitives are used for:
//! - RLP encoding (`primitives.Rlp`)
//! - Keccak256 hashing (`crypto.keccak256`)
//!
//! ## Usage
//!
//! ```zig
//! const trie = @import("client_trie");
//!
//! // Compute root hash from key-value pairs.
//! // NOTE: keys must already be keccak256-prehashed for secure tries,
//! // and values must be RLP-encoded (e.g. transactions, receipts, accounts).
//! const root = try trie.trie_root(allocator, &keys, &values);
//! ```

const voltaire = @import("voltaire");

/// Hashing and patricialize implementation (from Voltaire).
pub const hash = voltaire.TrieHash;

// Re-export primary API
/// Compute the Merkle Patricia Trie root hash for key-value pairs.
pub const trie_root = hash.trie_root;
/// Compute the Merkle Patricia Trie root hash for secure (key-hashed) tries.
pub const secure_trie_root = hash.secure_trie_root;
/// Root hash for an empty trie (keccak256(RLP(""))).
pub const EMPTY_TRIE_ROOT = hash.EMPTY_TRIE_ROOT;

test {
    // Ensure all sub-modules compile and their tests run.
    @import("std").testing.refAllDecls(@This());
    _ = @import("fixtures.zig");
}

test "client_trie API smoke: empty root" {
    const std = @import("std");
    const testing = std.testing;

    const empty_keys: [0][]const u8 = .{};
    const empty_values: [0][]const u8 = .{};
    const root = try trie_root(testing.allocator, &empty_keys, &empty_values);
    try testing.expectEqual(EMPTY_TRIE_ROOT, root);
}
