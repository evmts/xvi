/// Chain management aliases backed by Voltaire primitives.
const std = @import("std");
const blockchain = @import("blockchain");
const primitives = @import("primitives");
const validator = @import("validator.zig");
const local_access = @import("local_access.zig");
const Block = primitives.Block;
const Hash = primitives.Hash;
const BlockHeader = primitives.BlockHeader;

/// Chain management handle backed by Voltaire's `Blockchain` primitive.
pub const Chain = blockchain.Blockchain;

const ForkBlockCache = blockchain.ForkBlockCache;

/// Returns the canonical head hash if present.
///
/// Semantics:
/// - Reads the current head block number; if none is set, returns null.
/// - Fetches the canonical block for that number and derives the hash from the
///   returned block (single-source snapshot) rather than consulting the
///   number→hash map separately.
/// - Race‑resilient snapshot: if the head changes during the read, a consistent
///   snapshot from the initial head number is returned rather than a stale mix
///   of values. This mirrors Nethermind’s snapshot semantics.
pub fn head_hash(chain: *Chain) !?Hash.Hash {
    // Delegate to the generic helper to avoid duplication and propagate errors.
    return try head_hash_of(chain);
}

/// Returns the canonical head block if present.
///
/// Semantics:
/// - Reads the current head block number; if none is set, returns null.
/// - Fetches the canonical block for that number in a single pass.
/// - Race‑resilient snapshot: if the head changes during the read, a consistent
///   snapshot from the initial head number is returned. Underlying errors (e.g.
///   `error.RpcPending` with a fork cache) are propagated.
pub fn head_block(chain: *Chain) !?Block.Block {
    // Delegate to the generic helper to avoid duplication.
    return head_block_of(chain);
}

/// Returns the canonical head block number if present.
///
/// Thin wrapper over Voltaire's `Blockchain.getHeadBlockNumber` to expose a
/// stable API from the client layer. Prefer this over calling the underlying
/// orchestrator directly to keep call sites decoupled.
pub fn head_number(chain: *Chain) ?u64 {
    return chain.getHeadBlockNumber();
}

/// Returns the pending block hash as the current canonical head hash (local-only).
///
/// Semantics:
/// - Mirrors Nethermind's `PendingHash` behavior where pending defaults to head.
/// - Uses only local head-number/canonical-hash snapshots; never fetches from
///   the fork cache and never allocates.
/// - Retries once when head changes during the read to avoid transient nulls.
pub fn pending_hash(chain: *Chain) ?Hash.Hash {
    return head_hash_snapshot_local(chain);
}

/// Returns the pending block as the current canonical head block (local-only).
///
/// Semantics:
/// - Mirrors Nethermind's `FindPendingBlock` behavior with `PendingHash => Head`.
/// - Uses local head snapshots only; never fetches from fork cache and never
///   allocates.
/// - Retries once when head changes during the read to avoid transient nulls.
pub fn pending_block(chain: *Chain) ?Block.Block {
    return head_block_snapshot_local(chain);
}

/// Returns true if the given hash is canonical at its block number (local-only).
///
/// Follows Nethermind semantics: compare the hash against the canonical mapping
/// for the block number using the local store only (no RPC or allocations).
/// Orphaned blocks are not canonical by definition.
pub fn is_canonical(chain: *Chain, hash: Hash.Hash) bool {
    // Local-only read via adapter helpers to avoid coupling to internals.
    const local = get_block_local(chain, hash) orelse return false;
    const number = local.header.number;
    const canonical = canonical_hash(chain, number) orelse return false;
    return Hash.equals(&canonical, &hash);
}

/// Returns true if the given hash is canonical, allowing fork-cache fetches.
///
/// Semantics:
/// - Tries local; if missing and a fork cache is configured, underlying call
///   may return `error.RpcPending` to request remote resolution.
/// - Preferred for performance when remote reads are acceptable.
pub fn is_canonical_or_fetch(chain: *Chain, hash: Hash.Hash) !bool {
    const maybe_block = try chain.getBlockByHash(hash);
    const block = maybe_block orelse return false;
    const number = block.header.number;
    const canonical = chain.getCanonicalHash(number) orelse return false;
    return Hash.equals(&canonical, &hash);
}

/// Returns true if the block is present locally or cached in the fork cache.
///
/// Thin wrapper over Voltaire `Blockchain.hasBlock` to keep client code
/// decoupled from the underlying orchestrator while adhering to Nethermind's
/// separation of concerns (storage/provider split).
pub fn has_block(chain: *Chain, hash: Hash.Hash) bool {
    return chain.hasBlock(hash);
}

/// Returns the canonical hash for a given block number (local-only).
///
/// Thin wrapper over Voltaire `Blockchain.getCanonicalHash` to keep client
/// code decoupled from the underlying orchestrator. Does not fetch from a
/// fork cache and performs no allocations.
pub fn canonical_hash(chain: *Chain, number: u64) ?Hash.Hash {
    return chain.getCanonicalHash(number);
}

/// Stores `block` in local chain storage via Voltaire's write path.
///
/// Semantics:
/// - Delegates to `Blockchain.putBlock` (local write only; no fork-cache writes).
/// - Preserves Voltaire orphan semantics: missing-parent blocks are stored and
///   tracked as orphans until ancestry is resolved.
/// - Propagates underlying write errors (e.g. `error.OutOfMemory`) explicitly.
pub fn put_block(chain: *Chain, block: Block.Block) !void {
    try chain.putBlock(block);
}

/// Sets the canonical head to `head_hash` using Voltaire's chain store logic.
///
/// Semantics:
/// - Mutates local canonical mappings only (no fork-cache reads/writes).
/// - Propagates underlying storage errors (e.g. `error.BlockNotFound`,
///   `error.CannotSetOrphanAsHead`, `error.OutOfMemory`) without suppression.
/// - Mirrors Nethermind's explicit head-update boundary (`UpdateHeadBlock`).
pub fn set_canonical_head(chain: *Chain, new_head_hash: Hash.Hash) !void {
    try chain.setCanonicalHead(new_head_hash);
}

/// Returns true if the given `(number, hash)` pair is canonical (local-only).
///
/// Semantics:
/// - Compares the provided `hash` against the canonical mapping for `number`.
/// - Never consults the fork cache; this is a pure local read.
/// - Mirrors Nethermind usage where callers often validate canonicality using
///   the number→hash mapping without reading the full block.
fn is_canonical_at(chain: *Chain, number: u64, hash: Hash.Hash) bool {
    const canonical = canonical_hash(chain, number) orelse return false;
    return Hash.equals(&canonical, &hash);
}

/// Returns true if the header's parent is canonical at `number - 1` (local-only).
///
/// Semantics:
/// - For `header.number == 0` (genesis), returns `false` — there is no parent
///   height to compare against and underflow must be avoided.
/// - Otherwise compares `header.parent_hash` with the canonical hash recorded
///   at `header.number - 1` via the local number→hash map.
/// - Never consults the fork cache and performs no allocations.
fn is_parent_canonical_local(
    chain: *Chain,
    header: *const BlockHeader.BlockHeader,
) bool {
    if (header.number == 0) return false;
    return is_canonical_at(chain, header.number - 1, header.parent_hash);
}

test "Chain - is_parent_canonical_local returns false for genesis header" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var hdr = BlockHeader.init();
    hdr.number = 0;
    hdr.parent_hash = Hash.ZERO;

    try std.testing.expect(!is_parent_canonical_local(&chain, &hdr));
}

test "Chain - is_parent_canonical_local returns true when parent canonical" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var hdr = BlockHeader.init();
    hdr.number = 1;
    hdr.parent_hash = genesis.hash;

    try std.testing.expect(is_parent_canonical_local(&chain, &hdr));
}

test "Chain - is_parent_canonical_local returns false on mismatch" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var hdr = BlockHeader.init();
    hdr.number = 1;
    hdr.parent_hash = Hash.ZERO; // not equal to canonical #0

    try std.testing.expect(!is_parent_canonical_local(&chain, &hdr));
}

test "Chain - is_parent_canonical_local returns false when parent mapping missing" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var hdr = BlockHeader.init();
    hdr.number = 1;
    hdr.parent_hash = Hash.ZERO;

    try std.testing.expect(!is_parent_canonical_local(&chain, &hdr));
}

// ---------------------------------------------------------------------------
// Comptime DI helpers (Nethermind-style parity)
// ---------------------------------------------------------------------------

/// Returns a block by hash from the local store only (no fork-cache fetch).
///
/// - Avoids allocations and remote requests.
/// - Mirrors Nethermind's storage/provider split where local reads are
///   explicit and do not cross abstraction boundaries.
pub fn get_block_local(chain: *Chain, hash: Hash.Hash) ?Block.Block {
    // Centralized local-only access via adapter to avoid field access leakage.
    return local_access.get_block_local(chain, hash);
}

/// Returns a canonical block by number from the local store only.
///
/// - Does not consult the fork cache or perform any allocations.
/// - Mirrors Nethermind semantics where local canonical lookups are explicit
///   and do not trigger remote fetches.
pub fn get_block_by_number_local(chain: *Chain, number: u64) ?Block.Block {
    // Centralized local-only access via adapter to avoid field access leakage.
    return local_access.get_block_by_number_local(chain, number);
}

/// Returns the parent block of the given header from the local store only.
///
/// - Does not consult the fork cache or perform any allocations.
/// - Mirrors Nethermind semantics where parent lookups at the storage layer
///   are explicit and never trigger remote fetches.
pub fn get_parent_block_local(chain: *Chain, header: *const BlockHeader.BlockHeader) ?Block.Block {
    return get_block_local(chain, header.parent_hash);
}

/// Returns the parent header from the local store or a typed error.
///
/// - Never consults the fork cache or performs allocations.
/// - Returns `ValidationError.MissingParentHeader` when the parent is not
///   present locally, so callers avoid nullable checks in validation paths.
pub fn parent_header_local(
    chain: *Chain,
    header: *const BlockHeader.BlockHeader,
) validator.ValidationError!BlockHeader.BlockHeader {
    const parent = get_parent_block_local(chain, header) orelse
        return validator.ValidationError.MissingParentHeader;
    return parent.header;
}

/// Returns the ancestor hash at `distance` from `start` using local store only.
///
/// Semantics:
/// - `distance == 0` returns `start` iff the start block exists locally.
/// - Walks parent links strictly via local storage; returns null if any
///   intermediate block is missing, parent-number continuity is malformed, or
///   when genesis has no parent.
/// - Never consults fork caches; performs no allocations.
const AncestorLookupError = error{
    MissingStartBlock,
    MissingAncestorBlock,
    MalformedAncestorBlock,
};

fn ancestor_hash_local(
    chain: *Chain,
    start: Hash.Hash,
    distance: u64,
) AncestorLookupError!Hash.Hash {
    var current_block = get_block_local(chain, start) orelse return error.MissingStartBlock;
    if (distance == 0) return current_block.hash;

    var i: u64 = 0;
    while (i < distance) : (i += 1) {
        if (current_block.header.number == 0) return error.MissingAncestorBlock; // genesis has no parent

        const parent_hash = current_block.header.parent_hash;
        const parent_block = get_block_local(chain, parent_hash) orelse return error.MissingAncestorBlock;
        if (parent_block.header.number != current_block.header.number - 1) {
            return error.MalformedAncestorBlock;
        }

        current_block = parent_block;
    }
    return current_block.hash;
}

/// Returns the `BLOCKHASH` value for `number` in an execution context.
///
/// Parameters:
/// - `tip_hash`: hash of the latest complete block in the execution context
///   (normally the parent hash of the currently executing block).
/// - `execution_block_number`: number of the currently executing block.
///
/// Semantics (execution-specs / EVM-compatible):
/// - `number` must be strictly lower than `execution_block_number`.
/// - Only the previous 256 blocks are addressable.
/// - `tip_hash` must correspond to block `execution_block_number - 1`.
/// - Uses local storage only; never fetches from fork cache and never allocates.
/// - Returns `null` when bounds fail, tip context is inconsistent, or ancestry
///   is incomplete/malformed in local storage.
pub const BlockHashByNumberError = error{
    MissingTipBlock,
    InconsistentTipContext,
    MissingAncestorBlock,
    MalformedAncestorBlock,
};

pub fn block_hash_by_number_local(
    chain: *Chain,
    tip_hash: Hash.Hash,
    execution_block_number: u64,
    number: u64,
) BlockHashByNumberError!?Hash.Hash {
    // EVM BLOCKHASH does not include current or future blocks.
    if (number >= execution_block_number) return null;

    // No complete block exists before genesis execution context.
    if (execution_block_number == 0) return null;

    const depth_from_execution = execution_block_number - number;
    if (depth_from_execution > 256) return null;

    const tip_block = get_block_local(chain, tip_hash) orelse return error.MissingTipBlock;
    if (tip_block.header.number + 1 != execution_block_number) return error.InconsistentTipContext;

    const distance_from_tip = depth_from_execution - 1;
    return ancestor_hash_local(chain, tip_hash, distance_from_tip) catch |err| switch (err) {
        error.MissingStartBlock => error.MissingTipBlock,
        error.MissingAncestorBlock => error.MissingAncestorBlock,
        error.MalformedAncestorBlock => error.MalformedAncestorBlock,
    };
}

/// Collects up to 256 recent block hashes from local storage in spec order.
///
/// Semantics:
/// - `tip_hash` must be the latest complete block hash for the execution
///   context (typically parent hash while executing the next block).
/// - Returns hashes ordered by increasing block number (oldest -> newest).
/// - Includes `tip_hash` as the last element when present.
/// - Fails closed with a typed error when in-range ancestry is missing or malformed.
/// - Never consults fork cache and performs no allocations.
pub const RecentBlockHashesError = error{
    MissingTipBlock,
    MissingAncestorBlock,
    MalformedAncestorBlock,
};

/// Collects up to 256 recent block hashes from local storage in spec order.
pub fn last_256_block_hashes_local(
    chain: *Chain,
    tip_hash: Hash.Hash,
    out: *[256]Hash.Hash,
) RecentBlockHashesError![]const Hash.Hash {
    const tip_block = get_block_local(chain, tip_hash) orelse return error.MissingTipBlock;
    const expected_len: usize = if (tip_block.header.number >= 255)
        256
    else
        @intCast(tip_block.header.number + 1);

    var write_start: usize = out.len;
    var cursor_hash = tip_hash;
    var cursor_block = tip_block;
    var written: usize = 0;

    while (written < expected_len) : (written += 1) {
        write_start -= 1;
        out[write_start] = cursor_hash;

        if (written + 1 == expected_len) break;
        if (cursor_block.header.number == 0) return error.MissingAncestorBlock;

        const expected_parent_number = cursor_block.header.number - 1;
        cursor_hash = cursor_block.header.parent_hash;
        cursor_block = get_block_local(chain, cursor_hash) orelse return error.MissingAncestorBlock;
        if (cursor_block.header.number != expected_parent_number) return error.MalformedAncestorBlock;
    }

    return out[write_start..];
}

/// Finds the lowest common ancestor hash of two blocks using local store only.
///
/// Semantics:
/// - Returns `null` if either `a` or `b` is missing locally.
/// - Walks strictly via parent links in the local store; never consults the
///   fork cache and performs no allocations.
/// - If `a == b` and exists locally, returns `a`.
/// - If the chains converge, returns the first matching hash when walking
///   upward; otherwise returns `null` (e.g., when an ancestor is missing
///   locally).
pub const CommonAncestorError = error{
    MissingBlockA,
    MissingBlockB,
    MissingAncestorBlock,
    MalformedAncestorBlock,
};

pub fn common_ancestor_hash_local(
    chain: *Chain,
    a: Hash.Hash,
    b: Hash.Hash,
) CommonAncestorError!?Hash.Hash {
    const na_block = get_block_local(chain, a) orelse return error.MissingBlockA;
    const nb_block = get_block_local(chain, b) orelse return error.MissingBlockB;

    // Fast path: identical hash and present locally.
    if (Hash.equals(&a, &b)) return a;

    var ha = na_block.header.number;
    var hb = nb_block.header.number;

    var ah = a;
    var bh = b;

    // Level heights by walking down the taller side first.
    while (ha > hb) : (ha -= 1) {
        const blk = get_block_local(chain, ah) orelse return error.MissingAncestorBlock;
        if (blk.header.number != ha) return error.MalformedAncestorBlock;
        if (ha == 0) return null;
        ah = blk.header.parent_hash;
    }
    while (hb > ha) : (hb -= 1) {
        const blk = get_block_local(chain, bh) orelse return error.MissingAncestorBlock;
        if (blk.header.number != hb) return error.MalformedAncestorBlock;
        if (hb == 0) return null;
        bh = blk.header.parent_hash;
    }

    // Walk in lockstep until hashes match or ancestry is missing locally.
    // In a valid chain, both sides can move up at most `ha + 1` times.
    // This guarantees termination even under malformed/cyclic ancestry.
    var level = ha;
    const remaining_hops_with_genesis, const hops_overflow = @addWithOverflow(ha, 1);
    if (hops_overflow != 0) return error.MalformedAncestorBlock;
    var remaining_hops = remaining_hops_with_genesis;
    while (remaining_hops > 0) : (remaining_hops -= 1) {
        const ab = get_block_local(chain, ah) orelse return error.MissingAncestorBlock;
        const bb = get_block_local(chain, bh) orelse return error.MissingAncestorBlock;
        if (ab.header.number != level or bb.header.number != level) return error.MalformedAncestorBlock;
        if (Hash.equals(&ah, &bh)) return ah;
        if (level == 0) return null;
        ah = ab.header.parent_hash;
        bh = bb.header.parent_hash;
        level -= 1;
    }
    return null;
}

/// Returns true when candidate head is on a different branch than canonical head.
///
/// Semantics:
/// - Uses local store only and never fetches from fork cache.
/// - Returns `false` when canonical head is unavailable locally.
/// - Returns `false` when candidate is equal to canonical head, extends it, or
///   is its ancestor.
/// - Returns `true` only when both heads have a common ancestor that is neither
///   head (i.e., actual fork divergence that implies reorg when adopted).
const CanonicalHeadSnapshotError = error{
    MissingCanonicalHash,
    MissingCanonicalHeadBlock,
    MalformedCanonicalHead,
};

fn canonical_head_hash_snapshot_local(chain: *Chain) CanonicalHeadSnapshotError!?Hash.Hash {
    const number = head_number(chain) orelse return null;
    const canonical = canonical_hash(chain, number) orelse return error.MissingCanonicalHash;
    const block = get_block_local(chain, canonical) orelse return error.MissingCanonicalHeadBlock;
    if (block.header.number != number) return error.MalformedCanonicalHead;
    return canonical;
}

fn head_hash_snapshot_local_with_policy(chain: *Chain, max_attempts: usize) ?Hash.Hash {
    const attempts = @max(max_attempts, 1);
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        const before = head_number(chain) orelse return null;
        const maybe_hash = canonical_hash(chain, before);
        const hash = maybe_hash orelse {
            if (attempt + 1 == attempts) return null;
            continue;
        };
        const after = head_number(chain) orelse return null;
        if (after == before) return hash;
        if (attempt + 1 == attempts) return hash; // return the "before" snapshot
    }
    return null; // defensive
}

fn head_hash_snapshot_local(chain: *Chain) ?Hash.Hash {
    return head_hash_snapshot_local_with_policy(chain, 2);
}

fn head_block_snapshot_local_with_policy(chain: *Chain, max_attempts: usize) ?Block.Block {
    const attempts = @max(max_attempts, 1);
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        const before = head_number(chain) orelse return null;
        const maybe_block = get_block_by_number_local(chain, before);
        const block = maybe_block orelse {
            if (attempt + 1 == attempts) return null;
            continue;
        };
        const after = head_number(chain) orelse return null;
        if (after == before) return block;
        if (attempt + 1 == attempts) return block; // return the "before" snapshot
    }
    return null; // defensive
}

fn head_block_snapshot_local(chain: *Chain) ?Block.Block {
    return head_block_snapshot_local_with_policy(chain, 2);
}

/// Returns whether `candidate_head` diverges from the current canonical head.
pub const CanonicalDivergenceError = CanonicalHeadSnapshotError || CommonAncestorError;

pub fn has_canonical_divergence_local(
    chain: *Chain,
    candidate_head: Hash.Hash,
) CanonicalDivergenceError!bool {
    const canonical_head = (try canonical_head_hash_snapshot_local(chain)) orelse return false;

    if (Hash.equals(&canonical_head, &candidate_head)) return false;

    const ancestor = (try common_ancestor_hash_local(chain, canonical_head, candidate_head)) orelse return false;
    if (Hash.equals(&ancestor, &canonical_head)) return false; // candidate extends current head
    if (Hash.equals(&ancestor, &candidate_head)) return false; // candidate is an older canonical ancestor
    return true;
}

const ReorgDepthContext = struct {
    canonical_head_number: u64,
    candidate_head_number: u64,
    ancestor_number: u64,
};

const ReorgDepthContextError = CanonicalHeadSnapshotError || CommonAncestorError || error{
    MissingCanonicalHeadBlock,
    MissingCandidateHeadBlock,
    MissingCommonAncestorBlock,
};

fn reorg_depth_context_local(
    chain: *Chain,
    candidate_head: Hash.Hash,
) ReorgDepthContextError!?ReorgDepthContext {
    const canonical_head = (try canonical_head_hash_snapshot_local(chain)) orelse return null;
    const canonical_head_block = get_block_local(chain, canonical_head) orelse return error.MissingCanonicalHeadBlock;
    const candidate_head_block = get_block_local(chain, candidate_head) orelse return error.MissingCandidateHeadBlock;
    const ancestor = (try common_ancestor_hash_local(chain, canonical_head, candidate_head)) orelse return null;
    const ancestor_block = get_block_local(chain, ancestor) orelse return error.MissingCommonAncestorBlock;

    return .{
        .canonical_head_number = canonical_head_block.header.number,
        .candidate_head_number = candidate_head_block.header.number,
        .ancestor_number = ancestor_block.header.number,
    };
}

/// Returns local-only reorg depth from canonical head to common ancestor.
///
/// Semantics:
/// - Uses local store only and never fetches from fork cache.
/// - Returns `null` when canonical head snapshot is unavailable, candidate is
///   missing locally, or no local common ancestor can be established.
/// - Returns `0` when candidate equals canonical head or extends canonical
///   head (ancestor is canonical head).
/// - Otherwise returns `canonical_head.number - ancestor.number`, i.e. the
///   number of canonical blocks that would be rolled back if candidate became
///   canonical.
pub const ReorgDepthError = ReorgDepthContextError || error{MalformedReorgContext};

pub fn canonical_reorg_depth_local(
    chain: *Chain,
    candidate_head: Hash.Hash,
) ReorgDepthError!?u64 {
    const ctx = (try reorg_depth_context_local(chain, candidate_head)) orelse return null;

    if (ctx.ancestor_number > ctx.canonical_head_number) return error.MalformedReorgContext;
    return ctx.canonical_head_number - ctx.ancestor_number;
}

/// Returns local-only candidate-branch depth from candidate head to common ancestor.
///
/// Semantics:
/// - Uses local store only and never fetches from fork cache.
/// - Returns `null` when canonical head snapshot is unavailable, candidate is
///   missing locally, or no local common ancestor can be established.
/// - Returns `0` when candidate equals canonical head or is a canonical
///   ancestor (ancestor is candidate).
/// - Returns `candidate_head.number - ancestor.number`, i.e. the number of
///   candidate-branch blocks that would be applied if candidate became
///   canonical.
pub fn candidate_reorg_depth_local(
    chain: *Chain,
    candidate_head: Hash.Hash,
) ReorgDepthError!?u64 {
    const ctx = (try reorg_depth_context_local(chain, candidate_head)) orelse return null;

    if (ctx.ancestor_number > ctx.candidate_head_number) return error.MalformedReorgContext;
    return ctx.candidate_head_number - ctx.ancestor_number;
}

test "Chain - common_ancestor_hash_local returns typed error when either missing" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expectError(error.MissingBlockA, common_ancestor_hash_local(&chain, Hash.ZERO, Hash.ZERO));
}

test "Chain - common_ancestor_hash_local returns self when equal" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const lca = (try common_ancestor_hash_local(&chain, genesis.hash, genesis.hash)) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &lca);
}

test "Chain - common_ancestor_hash_local finds ancestor on same chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);

    var h2 = primitives.BlockHeader.init();
    h2.number = 2;
    h2.parent_hash = b1.hash;
    const b2 = try Block.from(&h2, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b2);

    const lca = (try common_ancestor_hash_local(&chain, b1.hash, b2.hash)) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &b1.hash, &lca);
}

test "Chain - common_ancestor_hash_local finds ancestor across fork" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    // First child A1
    var h1a = primitives.BlockHeader.init();
    h1a.number = 1;
    h1a.parent_hash = genesis.hash;
    h1a.timestamp = 1;
    const b1a = try Block.from(&h1a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1a);

    // Competing child B1
    var h1b = primitives.BlockHeader.init();
    h1b.number = 1;
    h1b.parent_hash = genesis.hash;
    h1b.timestamp = 2;
    const b1b = try Block.from(&h1b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1b);

    const lca = (try common_ancestor_hash_local(&chain, b1a.hash, b1b.hash)) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &lca);
}

test "Chain - common_ancestor_hash_local returns typed error when ancestry missing locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    // Orphan blocks (distinct parents not present locally)
    var h_a = primitives.BlockHeader.init();
    h_a.number = 5;
    h_a.parent_hash = [_]u8{0x11} ** 32;
    const a = try Block.from(&h_a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(a);

    var h_b = primitives.BlockHeader.init();
    h_b.number = 7;
    h_b.parent_hash = [_]u8{0x22} ** 32;
    const b = try Block.from(&h_b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b);

    try std.testing.expectError(error.MissingAncestorBlock, common_ancestor_hash_local(&chain, a.hash, b.hash));
}

test "Chain - common_ancestor_hash_local returns typed error for cyclic ancestry" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    // Malformed blocks: parent links point to themselves.
    var h_a = primitives.BlockHeader.init();
    h_a.number = 9;
    h_a.timestamp = 1;
    const a0 = try Block.from(&h_a, &primitives.BlockBody.init(), allocator);
    var a = a0;
    a.header.parent_hash = a.hash;
    try chain.putBlock(a);

    var h_b = primitives.BlockHeader.init();
    h_b.number = 9;
    h_b.timestamp = 2;
    const b0 = try Block.from(&h_b, &primitives.BlockBody.init(), allocator);
    var b = b0;
    b.header.parent_hash = b.hash;
    try chain.putBlock(b);

    try std.testing.expectError(error.MalformedAncestorBlock, common_ancestor_hash_local(&chain, a.hash, b.hash));
}

test "Chain - common_ancestor_hash_local returns typed error for non-contiguous ancestry" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    // Malformed branches: height jumps directly to genesis as parent.
    var h_a = primitives.BlockHeader.init();
    h_a.number = 4;
    h_a.parent_hash = genesis.hash;
    h_a.timestamp = 1;
    const a = try Block.from(&h_a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(a);

    var h_b = primitives.BlockHeader.init();
    h_b.number = 4;
    h_b.parent_hash = genesis.hash;
    h_b.timestamp = 2;
    const b = try Block.from(&h_b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b);

    try std.testing.expectError(error.MalformedAncestorBlock, common_ancestor_hash_local(&chain, a.hash, b.hash));
}

test "Chain - has_canonical_divergence_local returns false for empty canonical chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect(!(try has_canonical_divergence_local(&chain, Hash.ZERO)));
}

test "Chain - has_canonical_divergence_local returns false for current canonical head" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    try std.testing.expect(!(try has_canonical_divergence_local(&chain, genesis.hash)));
}

test "Chain - has_canonical_divergence_local returns false when candidate extends canonical head" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);

    try std.testing.expect(!(try has_canonical_divergence_local(&chain, b1.hash)));
}

test "Chain - has_canonical_divergence_local returns true for forked candidate head" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1a = primitives.BlockHeader.init();
    h1a.number = 1;
    h1a.parent_hash = genesis.hash;
    h1a.timestamp = 1;
    const b1a = try Block.from(&h1a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1a);
    try chain.setCanonicalHead(b1a.hash);

    var h1b = primitives.BlockHeader.init();
    h1b.number = 1;
    h1b.parent_hash = genesis.hash;
    h1b.timestamp = 2;
    const b1b = try Block.from(&h1b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1b);

    try std.testing.expect(try has_canonical_divergence_local(&chain, b1b.hash));
}

test "Chain - has_canonical_divergence_local returns false when candidate is canonical ancestor" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);
    try chain.setCanonicalHead(b1.hash);

    var h2 = primitives.BlockHeader.init();
    h2.number = 2;
    h2.parent_hash = b1.hash;
    h2.timestamp = 2;
    const b2 = try Block.from(&h2, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b2);
    try chain.setCanonicalHead(b2.hash);

    try std.testing.expect(!(try has_canonical_divergence_local(&chain, b1.hash)));
}

test "Chain - has_canonical_divergence_local returns typed error when ancestry missing locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var orphan_h = primitives.BlockHeader.init();
    orphan_h.number = 9;
    orphan_h.parent_hash = [_]u8{0x33} ** 32;
    orphan_h.timestamp = 9;
    const orphan = try Block.from(&orphan_h, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(orphan);

    try std.testing.expectError(error.MissingAncestorBlock, has_canonical_divergence_local(&chain, orphan.hash));
}

test "Chain - has_canonical_divergence_local returns typed error for non-contiguous candidate ancestry" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var malformed_h = primitives.BlockHeader.init();
    malformed_h.number = 5;
    malformed_h.parent_hash = genesis.hash;
    malformed_h.timestamp = 5;
    const malformed = try Block.from(&malformed_h, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(malformed);

    try std.testing.expectError(error.MalformedAncestorBlock, has_canonical_divergence_local(&chain, malformed.hash));
}

test "Chain - canonical_reorg_depth_local returns null for empty canonical chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect((try canonical_reorg_depth_local(&chain, Hash.ZERO)) == null);
}

test "Chain - canonical_reorg_depth_local returns zero for canonical head" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    try std.testing.expectEqual(@as(u64, 0), (try canonical_reorg_depth_local(&chain, genesis.hash)) orelse return error.Unreachable);
}

test "Chain - canonical_reorg_depth_local returns zero when candidate extends canonical head" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);

    try std.testing.expectEqual(@as(u64, 0), (try canonical_reorg_depth_local(&chain, b1.hash)) orelse return error.Unreachable);
}

test "Chain - canonical_reorg_depth_local returns one for sibling fork at height one" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1a = primitives.BlockHeader.init();
    h1a.number = 1;
    h1a.parent_hash = genesis.hash;
    h1a.timestamp = 1;
    const b1a = try Block.from(&h1a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1a);
    try chain.setCanonicalHead(b1a.hash);

    var h1b = primitives.BlockHeader.init();
    h1b.number = 1;
    h1b.parent_hash = genesis.hash;
    h1b.timestamp = 2;
    const b1b = try Block.from(&h1b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1b);

    try std.testing.expectEqual(@as(u64, 1), (try canonical_reorg_depth_local(&chain, b1b.hash)) orelse return error.Unreachable);
}

test "Chain - canonical_reorg_depth_local returns rollback depth for deeper fork" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1a = primitives.BlockHeader.init();
    h1a.number = 1;
    h1a.parent_hash = genesis.hash;
    h1a.timestamp = 1;
    const b1a = try Block.from(&h1a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1a);
    try chain.setCanonicalHead(b1a.hash);

    var h2a = primitives.BlockHeader.init();
    h2a.number = 2;
    h2a.parent_hash = b1a.hash;
    h2a.timestamp = 2;
    const b2a = try Block.from(&h2a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b2a);
    try chain.setCanonicalHead(b2a.hash);

    var h3a = primitives.BlockHeader.init();
    h3a.number = 3;
    h3a.parent_hash = b2a.hash;
    h3a.timestamp = 3;
    const b3a = try Block.from(&h3a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b3a);
    try chain.setCanonicalHead(b3a.hash);

    var h2b = primitives.BlockHeader.init();
    h2b.number = 2;
    h2b.parent_hash = b1a.hash;
    h2b.timestamp = 4;
    const b2b = try Block.from(&h2b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b2b);

    var h3b = primitives.BlockHeader.init();
    h3b.number = 3;
    h3b.parent_hash = b2b.hash;
    h3b.timestamp = 5;
    const b3b = try Block.from(&h3b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b3b);

    try std.testing.expectEqual(@as(u64, 2), (try canonical_reorg_depth_local(&chain, b3b.hash)) orelse return error.Unreachable);
}

test "Chain - canonical_reorg_depth_local returns typed error when ancestry missing locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var orphan_h = primitives.BlockHeader.init();
    orphan_h.number = 9;
    orphan_h.parent_hash = [_]u8{0x44} ** 32;
    orphan_h.timestamp = 9;
    const orphan = try Block.from(&orphan_h, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(orphan);

    try std.testing.expectError(error.MissingAncestorBlock, canonical_reorg_depth_local(&chain, orphan.hash));
}

test "Chain - canonical_reorg_depth_local returns typed error for non-contiguous candidate ancestry" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var malformed_h = primitives.BlockHeader.init();
    malformed_h.number = 5;
    malformed_h.parent_hash = genesis.hash;
    malformed_h.timestamp = 5;
    const malformed = try Block.from(&malformed_h, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(malformed);

    try std.testing.expectError(error.MalformedAncestorBlock, canonical_reorg_depth_local(&chain, malformed.hash));
}

test "Chain - candidate_reorg_depth_local returns null for empty canonical chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect((try candidate_reorg_depth_local(&chain, Hash.ZERO)) == null);
}

test "Chain - candidate_reorg_depth_local returns zero for canonical head" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    try std.testing.expectEqual(@as(u64, 0), (try candidate_reorg_depth_local(&chain, genesis.hash)) orelse return error.Unreachable);
}

test "Chain - candidate_reorg_depth_local returns one when candidate extends canonical head" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);

    try std.testing.expectEqual(@as(u64, 1), (try candidate_reorg_depth_local(&chain, b1.hash)) orelse return error.Unreachable);
}

test "Chain - candidate_reorg_depth_local returns one for sibling fork at height one" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1a = primitives.BlockHeader.init();
    h1a.number = 1;
    h1a.parent_hash = genesis.hash;
    h1a.timestamp = 1;
    const b1a = try Block.from(&h1a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1a);
    try chain.setCanonicalHead(b1a.hash);

    var h1b = primitives.BlockHeader.init();
    h1b.number = 1;
    h1b.parent_hash = genesis.hash;
    h1b.timestamp = 2;
    const b1b = try Block.from(&h1b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1b);

    try std.testing.expectEqual(@as(u64, 1), (try candidate_reorg_depth_local(&chain, b1b.hash)) orelse return error.Unreachable);
}

test "Chain - candidate_reorg_depth_local returns apply depth for deeper fork" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1a = primitives.BlockHeader.init();
    h1a.number = 1;
    h1a.parent_hash = genesis.hash;
    h1a.timestamp = 1;
    const b1a = try Block.from(&h1a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1a);
    try chain.setCanonicalHead(b1a.hash);

    var h2a = primitives.BlockHeader.init();
    h2a.number = 2;
    h2a.parent_hash = b1a.hash;
    h2a.timestamp = 2;
    const b2a = try Block.from(&h2a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b2a);
    try chain.setCanonicalHead(b2a.hash);

    var h3a = primitives.BlockHeader.init();
    h3a.number = 3;
    h3a.parent_hash = b2a.hash;
    h3a.timestamp = 3;
    const b3a = try Block.from(&h3a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b3a);
    try chain.setCanonicalHead(b3a.hash);

    var h2b = primitives.BlockHeader.init();
    h2b.number = 2;
    h2b.parent_hash = b1a.hash;
    h2b.timestamp = 4;
    const b2b = try Block.from(&h2b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b2b);

    var h3b = primitives.BlockHeader.init();
    h3b.number = 3;
    h3b.parent_hash = b2b.hash;
    h3b.timestamp = 5;
    const b3b = try Block.from(&h3b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b3b);

    try std.testing.expectEqual(@as(u64, 2), (try candidate_reorg_depth_local(&chain, b3b.hash)) orelse return error.Unreachable);
}

test "Chain - candidate_reorg_depth_local returns zero when candidate is canonical ancestor" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);
    try chain.setCanonicalHead(b1.hash);

    var h2 = primitives.BlockHeader.init();
    h2.number = 2;
    h2.parent_hash = b1.hash;
    h2.timestamp = 2;
    const b2 = try Block.from(&h2, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b2);
    try chain.setCanonicalHead(b2.hash);

    try std.testing.expectEqual(@as(u64, 0), (try candidate_reorg_depth_local(&chain, b1.hash)) orelse return error.Unreachable);
}

test "Chain - candidate_reorg_depth_local returns typed error when ancestry missing locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var orphan_h = primitives.BlockHeader.init();
    orphan_h.number = 9;
    orphan_h.parent_hash = [_]u8{0x55} ** 32;
    orphan_h.timestamp = 9;
    const orphan = try Block.from(&orphan_h, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(orphan);

    try std.testing.expectError(error.MissingAncestorBlock, candidate_reorg_depth_local(&chain, orphan.hash));
}

test "Chain - candidate_reorg_depth_local returns typed error for non-contiguous candidate ancestry" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var malformed_h = primitives.BlockHeader.init();
    malformed_h.number = 5;
    malformed_h.parent_hash = genesis.hash;
    malformed_h.timestamp = 5;
    const malformed = try Block.from(&malformed_h, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(malformed);

    try std.testing.expectError(error.MalformedAncestorBlock, candidate_reorg_depth_local(&chain, malformed.hash));
}

/// Generic, comptime-injected head hash reader for any chain-like type.
pub fn head_hash_of(chain: anytype) !?Hash.Hash {
    return head_hash_of_with_policy(chain, 2);
}

/// Generic, comptime-injected head hash reader with configurable retry policy.
///
/// Parameters:
/// - `max_attempts`: number of reads allowed when head changes during read.
///   Uses canonical number->hash mapping when available to avoid full block
///   reads on hot hash-only paths.
pub fn head_hash_of_with_policy(chain: anytype, max_attempts: usize) !?Hash.Hash {
    const attempts = @max(max_attempts, 1);
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        const before = chain.getHeadBlockNumber() orelse return null;
        const maybe_hash = try head_hash_at_number(chain, before);
        const hh = maybe_hash orelse return null;
        const after = chain.getHeadBlockNumber() orelse return null;
        if (after == before) return hh;
        if (attempt + 1 == attempts) return hh; // return 'before' snapshot
    }
    return null; // defensive
}

fn head_hash_at_number(chain: anytype, number: u64) !?Hash.Hash {
    const ChainType = switch (@typeInfo(@TypeOf(chain))) {
        .pointer => |ptr| ptr.child,
        else => @TypeOf(chain),
    };

    // Prefer hash-only lookup to avoid full block reads on hot paths.
    if (@hasDecl(ChainType, "getCanonicalHash")) {
        return chain.getCanonicalHash(number);
    }

    // Fallback for chain-like types that expose only block-by-number.
    const maybe_block = try chain.getBlockByNumber(number);
    return if (maybe_block) |b| b.hash else null;
}

/// Generic, comptime-injected head block reader with configurable retry policy.
///
/// Parameters:
/// - `max_attempts`: number of reads allowed when head changes during read.
///   Trade-off: higher values increase stability under contention but add extra
///   reads. Default of 2 mirrors Nethermind snapshot semantics (one retry,
///   then return the first consistent snapshot). Values below 1 are clamped
///   to 1 to avoid silent null snapshots.
pub fn head_block_of_with_policy(chain: anytype, max_attempts: usize) !?Block.Block {
    const attempts = @max(max_attempts, 1);
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        const before = chain.getHeadBlockNumber() orelse return null;
        const maybe_block = try chain.getBlockByNumber(before);
        const hb = maybe_block orelse return null;
        const after = chain.getHeadBlockNumber() orelse return null;
        if (after == before) return hb;
        if (attempt + 1 == attempts) return hb; // return 'before' snapshot
    }
    return null; // defensive
}

/// Generic, comptime-injected head block reader for any chain-like type.
/// Uses default retry policy of 2 attempts; see `head_block_of_with_policy`.
pub fn head_block_of(chain: anytype) !?Block.Block {
    return head_block_of_with_policy(chain, 2);
}

/// Generic, comptime-injected head number reader for any chain-like type.
///
/// The provided `chain` must define `getHeadBlockNumber() -> ?u64`.
pub fn head_number_of(chain: anytype) ?u64 {
    return chain.getHeadBlockNumber();
}

/// Forkchoice view provider interface (duck-typed via comptime DI).
///
/// Expected minimal API:
/// - `getSafeHash() -> ?Hash.Hash`
/// - `getFinalizedHash() -> ?Hash.Hash`
///
/// These helpers intentionally do not fetch; pair with `*_or_fetch` variants if
/// remote reads are acceptable in the call site.
pub fn safe_head_hash_of(fc: anytype) ?Hash.Hash {
    // Intentionally a thin wrapper to keep DI surface consistent. Callers
    // should pass `*fc` by convention; we do not enforce pointer receivers at
    // comptime as it reduces DI flexibility and diverges from repo style.
    return fc.getSafeHash();
}

/// Returns the finalized-head hash from a forkchoice provider.
pub fn finalized_head_hash_of(fc: anytype) ?Hash.Hash {
    // Intentionally a thin wrapper to keep DI surface consistent. Callers
    // should pass `*fc` by convention; we do not enforce pointer receivers at
    // comptime as it reduces DI flexibility and diverges from repo style.
    return fc.getFinalizedHash();
}

inline fn block_from_hash_opt(chain: *Chain, maybe_hash: ?Hash.Hash) ?Block.Block {
    const h = maybe_hash orelse return null;
    return get_block_local(chain, h);
}

/// Local-only safe head block lookup (no fork-cache fetch/allocations at this layer).
pub fn safe_head_block_of(chain: *Chain, fc: anytype) ?Block.Block {
    // Local-only view; use fork-cache layer at call sites if remote fetches are acceptable.
    return block_from_hash_opt(chain, safe_head_hash_of(fc));
}

/// Local-only finalized head block lookup (no fork-cache fetch/allocations at this layer).
pub fn finalized_head_block_of(chain: *Chain, fc: anytype) ?Block.Block {
    // Local-only view; use fork-cache layer at call sites if remote fetches are acceptable.
    return block_from_hash_opt(chain, finalized_head_hash_of(fc));
}

test {
    @import("std").testing.refAllDecls(@This());
}

fn fetch_remote_block_zero_for_test(
    chain: *Chain,
    fork_cache: *ForkBlockCache,
    allocator: std.mem.Allocator,
    hash_hex: []const u8,
) !Block.Block {
    try std.testing.expectError(error.RpcPending, chain.getBlockByNumber(0));
    const req = fork_cache.nextRequest() orelse return error.UnexpectedNull;
    const response = try std.fmt.allocPrint(
        allocator,
        "{{\"hash\":\"{s}\",\"number\":\"0x0\"}}",
        .{hash_hex},
    );
    defer allocator.free(response);
    try fork_cache.continueRequest(req.id, response);
    return (try chain.getBlockByNumber(0)) orelse return error.UnexpectedNull;
}

const TestForkchoice = struct {
    safe: ?Hash.Hash,
    finalized: ?Hash.Hash,

    pub fn getSafeHash(self: *const @This()) ?Hash.Hash {
        return self.safe;
    }

    pub fn getFinalizedHash(self: *const @This()) ?Hash.Hash {
        return self.finalized;
    }
};

const RacingHeadChain = struct {
    head_number: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    slow_first_lookup: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    first_block: Block.Block,
    second_block: Block.Block,

    pub fn getHeadBlockNumber(self: *@This()) ?u64 {
        return self.head_number.load(.acquire);
    }

    pub fn getCanonicalHash(self: *@This(), number: u64) ?Hash.Hash {
        return switch (number) {
            1 => self.first_block.hash,
            2 => self.second_block.hash,
            else => null,
        };
    }

    pub fn getBlockByNumber(self: *@This(), number: u64) !?Block.Block {
        if (number == 1 and self.slow_first_lookup.swap(false, .acq_rel)) {
            // Allow the mover thread to advance head between before/after reads.
            std.Thread.sleep(2 * std.time.ns_per_ms);
        }
        return switch (number) {
            1 => self.first_block,
            2 => self.second_block,
            else => null,
        };
    }

    pub fn moveHeadAfterDelay(self: *@This(), next_head: u64, delay_ns: u64) void {
        std.Thread.sleep(delay_ns);
        self.head_number.store(next_head, .release);
    }
};

test "Chain - missing blocks return null" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const by_hash = try chain.getBlockByHash(primitives.Hash.ZERO);
    try std.testing.expect(by_hash == null);

    const by_number = try chain.getBlockByNumber(0);
    try std.testing.expect(by_number == null);
}

test "Chain - fork cache RpcPending propagates" {
    const allocator = std.testing.allocator;
    var fork_cache = try ForkBlockCache.init(allocator, 1024);
    defer fork_cache.deinit();

    var chain = try Chain.init(allocator, &fork_cache);
    defer chain.deinit();

    try std.testing.expectError(error.RpcPending, chain.getBlockByNumber(0));
    try std.testing.expectError(error.RpcPending, chain.getBlockByHash(primitives.Hash.ZERO));
}

test "Chain - head_hash returns null for empty chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect((try head_hash(&chain)) == null);
}

test "Chain - head_hash returns canonical head hash" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const hash = try head_hash(&chain);
    try std.testing.expect(hash != null);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hash.?);
}

test "Chain - head_block returns null for empty chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const hb = try head_block(&chain);
    try std.testing.expect(hb == null);
}

test "Chain - head_block returns canonical head block" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const hb1 = try head_block(&chain);
    try std.testing.expect(hb1 != null);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hb1.?.hash);
}

test "Chain - head_number returns null for empty chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect(head_number(&chain) == null);
}

test "Chain - head_number returns canonical number and updates after reorg" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const n0 = head_number(&chain);
    try std.testing.expect(n0 != null);
    try std.testing.expectEqual(@as(u64, 0), n0.?);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);
    try chain.setCanonicalHead(b1.hash);

    const n1 = head_number(&chain);
    try std.testing.expect(n1 != null);
    try std.testing.expectEqual(@as(u64, 1), n1.?);
}

test "Chain - pending_hash returns null for empty chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect(pending_hash(&chain) == null);
}

test "Chain - pending_hash returns canonical head hash" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const hash = pending_hash(&chain) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hash);
}

test "Chain - pending_block returns null for empty chain" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect(pending_block(&chain) == null);
}

test "Chain - pending_block returns canonical head block" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const block = pending_block(&chain) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &block.hash);
    try std.testing.expectEqual(@as(u64, 0), block.header.number);
}

test "Chain - head_number_of forwards to underlying getter" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect(head_number_of(&chain) == null);

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const n = head_number_of(&chain);
    try std.testing.expect(n != null);
    try std.testing.expectEqual(@as(u64, 0), n.?);
}

test "Chain - head_block with fork cache and no head returns null (no fetch)" {
    const allocator = std.testing.allocator;
    var fork_cache = try ForkBlockCache.init(allocator, 16);
    defer fork_cache.deinit();

    var chain = try Chain.init(allocator, &fork_cache);
    defer chain.deinit();

    const hb = try head_block(&chain);
    try std.testing.expect(hb == null);
}

test "Chain - is_canonical returns false for missing block" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const some = Hash.ZERO;
    const result = is_canonical(&chain, some);
    try std.testing.expect(!result);
}

test "Chain - is_canonical returns true for canonical block" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const result_fetch = try is_canonical_or_fetch(&chain, genesis.hash);
    try std.testing.expect(result_fetch);
}

test "Chain - is_canonical returns false for orphan block" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    // Create an orphan (missing parent)
    var header = primitives.BlockHeader.init();
    header.number = 5;
    header.parent_hash = try Hash.fromHex("0x" ++ ("99" ** 32));
    const body = primitives.BlockBody.init();
    const orphan = try Block.from(&header, &body, allocator);
    try chain.putBlock(orphan);

    const result = is_canonical(&chain, orphan.hash);
    try std.testing.expect(!result);
}

test "Chain - is_canonical propagates RpcPending from fork cache" {
    const allocator = std.testing.allocator;
    var fork_cache = try ForkBlockCache.init(allocator, 16);
    defer fork_cache.deinit();

    var chain = try Chain.init(allocator, &fork_cache);
    defer chain.deinit();

    try std.testing.expectError(error.RpcPending, is_canonical_or_fetch(&chain, Hash.ZERO));
}

test "Chain - is_canonical local-only does not fetch and returns false" {
    const allocator = std.testing.allocator;
    var fork_cache = try ForkBlockCache.init(allocator, 16);
    defer fork_cache.deinit();

    var chain = try Chain.init(allocator, &fork_cache);
    defer chain.deinit();

    const some = Hash.ZERO;
    const result = is_canonical(&chain, some);
    try std.testing.expect(!result);
}

test "Chain - canonical_hash returns null for missing number" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expect(canonical_hash(&chain, 0) == null);
}

test "Chain - canonical_hash returns hash for canonical block" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const h = canonical_hash(&chain, 0) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &h);
}

test "Chain - set_canonical_head updates canonical head" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    try set_canonical_head(&chain, genesis.hash);

    try std.testing.expectEqual(@as(?u64, 0), head_number(&chain));
    const canonical = canonical_hash(&chain, 0) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &canonical);
}

test "Chain - set_canonical_head propagates missing block error" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expectError(error.BlockNotFound, set_canonical_head(&chain, Hash.ZERO));
}

test "Chain - put_block stores block locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try put_block(&chain, genesis);

    try std.testing.expect(has_block(&chain, genesis.hash));
    const stored = get_block_local(&chain, genesis.hash) orelse return error.Unreachable;
    try std.testing.expectEqual(@as(u64, 0), stored.header.number);
}

test "Chain - put_block stores orphan and preserves orphan semantics" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var header = primitives.BlockHeader.init();
    header.number = 5;
    header.parent_hash = try Hash.fromHex("0x" ++ ("77" ** 32));
    const body = primitives.BlockBody.init();
    const orphan = try Block.from(&header, &body, allocator);

    try put_block(&chain, orphan);

    try std.testing.expect(has_block(&chain, orphan.hash));
    try std.testing.expect(canonical_hash(&chain, orphan.header.number) == null);
    try std.testing.expectError(
        error.CannotSetOrphanAsHead,
        set_canonical_head(&chain, orphan.hash),
    );
}

test "Chain - is_canonical_at uses local canonical map" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    // Empty store → always false
    try std.testing.expect(!is_canonical_at(&chain, 0, Hash.ZERO));

    // Insert genesis and mark canonical
    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    try std.testing.expect(is_canonical_at(&chain, 0, genesis.hash));
    // Mismatch by number
    try std.testing.expect(!is_canonical_at(&chain, 1, genesis.hash));
    // Mismatch by hash
    try std.testing.expect(!is_canonical_at(&chain, 0, Hash.ZERO));
}

test "Chain - has_block reflects local and fork-cache presence" {
    const allocator = std.testing.allocator;

    // Local-only: missing → false, after insert → true
    {
        var chain = try Chain.init(allocator, null);
        defer chain.deinit();

        try std.testing.expect(!has_block(&chain, Hash.ZERO));

        const genesis = try Block.genesis(1, allocator);
        try chain.putBlock(genesis);
        try std.testing.expect(has_block(&chain, genesis.hash));
    }

    // With fork cache: cached remote block → true
    {
        var fork_cache = try ForkBlockCache.init(allocator, 1024);
        defer fork_cache.deinit();

        var chain = try Chain.init(allocator, &fork_cache);
        defer chain.deinit();

        // Queue a remote fetch by number, then supply a minimal JSON response
        const fetched = try fetch_remote_block_zero_for_test(
            &chain,
            &fork_cache,
            allocator,
            "0x" ++ ("22" ** 32),
        );

        // Verify has_block=true using the retrieved block's hash.
        try std.testing.expect(has_block(&chain, fetched.hash));
        if (get_block_local(&chain, fetched.hash) == null) try chain.putBlock(fetched);
        try chain.setCanonicalHead(fetched.hash);
        const ok_fetch = try is_canonical_or_fetch(&chain, fetched.hash);
        try std.testing.expect(ok_fetch);
    }
}

test "Chain - get_block_local reads only from local store" {
    const allocator = std.testing.allocator;

    // Local-only: missing → null, after insert → block
    {
        var chain = try Chain.init(allocator, null);
        defer chain.deinit();

        try std.testing.expect(get_block_local(&chain, Hash.ZERO) == null);

        const genesis = try Block.genesis(1, allocator);
        try chain.putBlock(genesis);
        const got = get_block_local(&chain, genesis.hash) orelse return error.Unreachable;
        try std.testing.expectEqualSlices(u8, &genesis.hash, &got.hash);
    }

    // With fork cache: block present only in cache → local read returns null
    {
        var fork_cache = try ForkBlockCache.init(allocator, 16);
        defer fork_cache.deinit();

        var chain = try Chain.init(allocator, &fork_cache);
        defer chain.deinit();

        // Queue a remote fetch by number and fulfill
        const fetched = try fetch_remote_block_zero_for_test(
            &chain,
            &fork_cache,
            allocator,
            "0x" ++ ("33" ** 32),
        );

        // Sanity: has_block should see cached remote
        try std.testing.expect(has_block(&chain, fetched.hash));
        // Local-only read must not see it
        try std.testing.expect(get_block_local(&chain, fetched.hash) == null);
    }
}

test "Chain - get_block_by_number_local reads canonical only and stays local" {
    const allocator = std.testing.allocator;

    // Local-only: before canonical set → null, after set → block
    {
        var chain = try Chain.init(allocator, null);
        defer chain.deinit();

        const genesis = try Block.genesis(1, allocator);
        try chain.putBlock(genesis);
        // Not canonical yet
        try std.testing.expect(get_block_by_number_local(&chain, 0) == null);
        try chain.setCanonicalHead(genesis.hash);
        const got0 = get_block_by_number_local(&chain, 0) orelse return error.Unreachable;
        try std.testing.expectEqual(@as(u64, 0), got0.header.number);

        // Non-existent number → null
        try std.testing.expect(get_block_by_number_local(&chain, 1) == null);
    }

    // With fork cache: block present only in cache by number → local read returns null
    {
        var fork_cache = try ForkBlockCache.init(allocator, 16);
        defer fork_cache.deinit();

        var chain = try Chain.init(allocator, &fork_cache);
        defer chain.deinit();

        // Request remote block #0 and fulfill
        const fetched = try fetch_remote_block_zero_for_test(
            &chain,
            &fork_cache,
            allocator,
            "0x" ++ ("44" ** 32),
        );

        // Sanity: unified getter sees it via cache, but local-by-number should not.
        try std.testing.expectEqual(@as(u64, 0), fetched.header.number);
        try std.testing.expect(get_block_by_number_local(&chain, 0) == null);
    }
}

test "Chain - get_parent_block_local returns null when parent missing locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var hdr = BlockHeader.init();
    hdr.parent_hash = Hash.ZERO;
    try std.testing.expect(get_parent_block_local(&chain, &hdr) == null);
}

test "Chain - get_parent_block_local returns parent when present locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    var hdr = BlockHeader.init();
    hdr.number = 1;
    hdr.parent_hash = genesis.hash;

    const parent = get_parent_block_local(&chain, &hdr) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &parent.hash);
}

test "Chain - get_parent_block_local ignores fork-cache-only parent" {
    const allocator = std.testing.allocator;
    var fork_cache = try ForkBlockCache.init(allocator, 16);
    defer fork_cache.deinit();

    var chain = try Chain.init(allocator, &fork_cache);
    defer chain.deinit();

    // Request remote block #0 and fulfill
    const fetched = try fetch_remote_block_zero_for_test(
        &chain,
        &fork_cache,
        allocator,
        "0x" ++ ("55" ** 32),
    );

    var hdr = BlockHeader.init();
    hdr.number = 1;
    hdr.parent_hash = fetched.hash;

    // Local-only parent lookup must not see fork-cache entries
    try std.testing.expect(get_parent_block_local(&chain, &hdr) == null);
}

test "Chain - parent_header_local returns typed error when parent missing locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var hdr = BlockHeader.init();
    hdr.parent_hash = Hash.ZERO;

    try std.testing.expectError(
        validator.ValidationError.MissingParentHeader,
        parent_header_local(&chain, &hdr),
    );
}

test "Chain - parent_header_local returns local parent header" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    var hdr = BlockHeader.init();
    hdr.number = 1;
    hdr.parent_hash = genesis.hash;

    const ph = try parent_header_local(&chain, &hdr);
    try std.testing.expectEqual(@as(u64, 0), ph.number);
}

test "Chain - parent_header_local ignores fork-cache-only parent and returns typed error" {
    const allocator = std.testing.allocator;
    var fork_cache = try ForkBlockCache.init(allocator, 16);
    defer fork_cache.deinit();

    var chain = try Chain.init(allocator, &fork_cache);
    defer chain.deinit();

    // Request remote block #0 and fulfill
    const fetched = try fetch_remote_block_zero_for_test(
        &chain,
        &fork_cache,
        allocator,
        "0x" ++ ("66" ** 32),
    );

    var hdr = BlockHeader.init();
    hdr.number = 1;
    hdr.parent_hash = fetched.hash;

    // Helper must not see fork-cache entries and should return typed error
    try std.testing.expectError(
        validator.ValidationError.MissingParentHeader,
        parent_header_local(&chain, &hdr),
    );
}

test "Chain - generic head helpers are race-resilient" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    // Snapshot helpers must return a consistent value
    const h1 = try head_hash_of(&chain);
    try std.testing.expect(h1 != null);
    const b1 = try head_block_of(&chain);
    try std.testing.expect(b1 != null);
}

test "Chain - head snapshot helpers tolerate concurrent head movement" {
    const allocator = std.testing.allocator;

    const genesis = try Block.genesis(1, allocator);
    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);

    // Single-attempt policy must return a consistent snapshot from the initial head.
    {
        var mock_one_attempt = RacingHeadChain{
            .first_block = genesis,
            .second_block = b1,
        };
        const mover = try std.Thread.spawn(.{}, RacingHeadChain.moveHeadAfterDelay, .{
            &mock_one_attempt,
            @as(u64, 2),
            1 * std.time.ns_per_ms,
        });
        defer mover.join();

        const one = try head_block_of_with_policy(&mock_one_attempt, 1);
        try std.testing.expect(one != null);
        try std.testing.expectEqualSlices(u8, &genesis.hash, &one.?.hash);
    }

    // Default policy (2 attempts) should converge to the moved head.
    {
        var mock_two_attempts = RacingHeadChain{
            .first_block = genesis,
            .second_block = b1,
        };
        const mover = try std.Thread.spawn(.{}, RacingHeadChain.moveHeadAfterDelay, .{
            &mock_two_attempts,
            @as(u64, 2),
            1 * std.time.ns_per_ms,
        });
        defer mover.join();

        const two = try head_block_of_with_policy(&mock_two_attempts, 2);
        try std.testing.expect(two != null);
        try std.testing.expectEqualSlices(u8, &b1.hash, &two.?.hash);

        const hh = try head_hash_of(&mock_two_attempts);
        try std.testing.expect(hh != null);
        try std.testing.expectEqualSlices(u8, &b1.hash, &hh.?);
    }
}

test "Chain - head_hash_of uses canonical hash path when available" {
    const allocator = std.testing.allocator;
    const genesis = try Block.genesis(1, allocator);

    const MockHashOnlyChain = struct {
        head_number: ?u64 = 0,
        canonical_hash: Hash.Hash,
        block_lookup_calls: usize = 0,

        pub fn getHeadBlockNumber(self: *@This()) ?u64 {
            return self.head_number;
        }

        pub fn getCanonicalHash(self: *@This(), number: u64) ?Hash.Hash {
            if (number != 0) return null;
            return self.canonical_hash;
        }

        pub fn getBlockByNumber(self: *@This(), _: u64) error{UnexpectedBlockLookup}!?Block.Block {
            self.block_lookup_calls += 1;
            return error.UnexpectedBlockLookup;
        }
    };

    var mock = MockHashOnlyChain{ .canonical_hash = genesis.hash };
    const hh = try head_hash_of(&mock);
    try std.testing.expect(hh != null);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hh.?);
    try std.testing.expectEqual(@as(usize, 0), mock.block_lookup_calls);
}

test "Chain - head_block_of_with_policy returns head snapshot" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const hb = try head_block_of_with_policy(&chain, 1);
    try std.testing.expect(hb != null);
    try std.testing.expectEqual(@as(u64, 0), hb.?.header.number);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hb.?.hash);
}

test "Chain - head_block_of_with_policy clamps zero attempts to one" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const hb = try head_block_of_with_policy(&chain, 0);
    try std.testing.expect(hb != null);
    try std.testing.expectEqual(@as(u64, 0), hb.?.header.number);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hb.?.hash);
}

test "Chain - is_canonical reflects reorgs" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    // First child (A1)
    var h1a = primitives.BlockHeader.init();
    h1a.number = 1;
    h1a.parent_hash = genesis.hash;
    h1a.timestamp = 1; // differ fields to ensure distinct hash
    const b1a = try Block.from(&h1a, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1a);

    try chain.setCanonicalHead(b1a.hash);
    var is_a1_canon = is_canonical(&chain, b1a.hash);
    try std.testing.expect(is_a1_canon);

    // Competing child (B1)
    var h1b = primitives.BlockHeader.init();
    h1b.number = 1;
    h1b.parent_hash = genesis.hash;
    h1b.timestamp = 2; // ensure different hash
    const b1b = try Block.from(&h1b, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1b);

    // Reorg to B1
    try chain.setCanonicalHead(b1b.hash);

    // Now A1 should be non-canonical, B1 canonical
    is_a1_canon = is_canonical(&chain, b1a.hash);
    try std.testing.expect(!is_a1_canon);
    const is_b1_canon = is_canonical(&chain, b1b.hash);
    try std.testing.expect(is_b1_canon);
}

test "Chain - head helpers reflect new head after reorg" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    try std.testing.expectEqualSlices(u8, &genesis.hash, &(try head_hash(&chain)).?);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);
    try chain.setCanonicalHead(b1.hash);

    const hh = try head_hash(&chain);
    try std.testing.expect(hh != null);
    try std.testing.expectEqualSlices(u8, &b1.hash, &hh.?);
}

test "Chain - safe_head_hash_of forwards forkchoice value" {
    var fc = TestForkchoice{ .safe = Hash.ZERO, .finalized = null };
    const h = safe_head_hash_of(&fc);
    try std.testing.expect(h != null);
    try std.testing.expectEqualSlices(u8, &Hash.ZERO, &h.?);
}

test "Chain - finalized_head_hash_of forwards forkchoice value" {
    var fc = TestForkchoice{ .safe = null, .finalized = Hash.ZERO };
    const h = finalized_head_hash_of(&fc);
    try std.testing.expect(h != null);
    try std.testing.expectEqualSlices(u8, &Hash.ZERO, &h.?);
}

test "Chain - safe/finalized head block helpers return local blocks" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    var fc = TestForkchoice{ .safe = genesis.hash, .finalized = genesis.hash };

    const sb = safe_head_block_of(&chain, &fc);
    try std.testing.expect(sb != null);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &sb.?.hash);

    const fb = finalized_head_block_of(&chain, &fc);
    try std.testing.expect(fb != null);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &fb.?.hash);
}

test "Chain - safe/finalized head block helpers return null when missing locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    // Some non-existent hash (all zeros is fine since store is empty)
    var fc = TestForkchoice{ .safe = Hash.ZERO, .finalized = Hash.ZERO };
    try std.testing.expect(safe_head_block_of(&chain, &fc) == null);
    try std.testing.expect(finalized_head_block_of(&chain, &fc) == null);
}

test "Chain - ancestor_hash_local returns typed error when start missing" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expectError(error.MissingStartBlock, ancestor_hash_local(&chain, Hash.ZERO, 0));
    try std.testing.expectError(error.MissingStartBlock, ancestor_hash_local(&chain, Hash.ZERO, 1));
}

test "Chain - ancestor_hash_local returns start for distance 0 when exists" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    const h = try ancestor_hash_local(&chain, genesis.hash, 0);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &h);
}

test "Chain - ancestor_hash_local returns parent for distance 1" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);

    const h = try ancestor_hash_local(&chain, b1.hash, 1);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &h);
}

test "Chain - ancestor_hash_local returns typed error for distance 1 from genesis" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    try std.testing.expectError(error.MissingAncestorBlock, ancestor_hash_local(&chain, genesis.hash, 1));
}

test "Chain - ancestor_hash_local returns typed error when orphan parent missing" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    // Orphan block with missing parent
    var hdr = primitives.BlockHeader.init();
    hdr.number = 7;
    hdr.parent_hash = try Hash.fromHex("0x" ++ ("aa" ** 32));
    const orphan = try Block.from(&hdr, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(orphan);

    try std.testing.expectError(error.MissingAncestorBlock, ancestor_hash_local(&chain, orphan.hash, 1));
}

test "Chain - block_hash_by_number_local returns typed error when tip missing" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    try std.testing.expectError(error.MissingTipBlock, block_hash_by_number_local(&chain, Hash.ZERO, 1, 0));
}

test "Chain - block_hash_by_number_local enforces current/future bounds" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);

    // Equal to current height: out of bounds.
    try std.testing.expect((try block_hash_by_number_local(&chain, b1.hash, 2, 2)) == null);
    // Future height: out of bounds.
    try std.testing.expect((try block_hash_by_number_local(&chain, b1.hash, 2, 3)) == null);
}

test "Chain - block_hash_by_number_local returns in-range ancestor hash" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var hashes: [258]Hash.Hash = undefined;

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    hashes[0] = genesis.hash;

    var parent_hash = genesis.hash;
    var i: u64 = 1;
    while (i < hashes.len) : (i += 1) {
        var hdr = primitives.BlockHeader.init();
        hdr.number = i;
        hdr.parent_hash = parent_hash;
        hdr.timestamp = i;
        const blk = try Block.from(&hdr, &primitives.BlockBody.init(), allocator);
        try chain.putBlock(blk);
        hashes[i] = blk.hash;
        parent_hash = blk.hash;
    }

    const tip = hashes[257];
    const execution_number: u64 = 258;

    // Depth 256 (max allowed) should still resolve.
    const oldest = (try block_hash_by_number_local(&chain, tip, execution_number, 2)) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &hashes[2], &oldest);

    // Parent block is always addressable at depth 1.
    const parent = (try block_hash_by_number_local(&chain, tip, execution_number, execution_number - 1)) orelse
        return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &tip, &parent);

    // Depth 256 (oldest in range) should still resolve.
    const oldest_in_range = (try block_hash_by_number_local(&chain, tip, execution_number, execution_number - 256)) orelse
        return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &hashes[2], &oldest_in_range);

    // Depth 257 is out of bounds.
    try std.testing.expect((try block_hash_by_number_local(&chain, tip, execution_number, execution_number - 257)) == null);
}

test "Chain - block_hash_by_number_local returns typed error for inconsistent tip context" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    // tip hash is genesis (#0), but execution number claims #2.
    try std.testing.expectError(error.InconsistentTipContext, block_hash_by_number_local(&chain, genesis.hash, 2, 1));
}

test "Chain - block_hash_by_number_local supports pending context parent lookup" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);

    // Executing block #2 with parent hash #1.
    const parent_hash = (try block_hash_by_number_local(&chain, b1.hash, 2, 1)) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &b1.hash, &parent_hash);

    // Current block number itself remains out of bounds.
    try std.testing.expect((try block_hash_by_number_local(&chain, b1.hash, 2, 2)) == null);
}

test "Chain - block_hash_by_number_local returns null when execution context is genesis" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    try std.testing.expect((try block_hash_by_number_local(&chain, genesis.hash, 0, 0)) == null);
}

test "Chain - block_hash_by_number_local returns typed error when ancestry missing locally" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    // Orphan block with missing parent at #299.
    var hdr = primitives.BlockHeader.init();
    hdr.number = 300;
    hdr.parent_hash = try Hash.fromHex("0x" ++ ("cc" ** 32));
    const orphan = try Block.from(&hdr, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(orphan);

    // Query parent of orphan parent (#299) which is missing locally.
    try std.testing.expectError(error.MissingAncestorBlock, block_hash_by_number_local(&chain, orphan.hash, 301, 299));
}

test "Chain - block_hash_by_number_local returns typed error for malformed parent-number continuity" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    // Malformed child: #2 points directly to #0.
    var hdr = primitives.BlockHeader.init();
    hdr.number = 2;
    hdr.parent_hash = genesis.hash;
    hdr.timestamp = 2;
    const malformed = try Block.from(&hdr, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(malformed);

    try std.testing.expectError(error.MalformedAncestorBlock, block_hash_by_number_local(&chain, malformed.hash, 3, 1));
}

test "Chain - block_hash_by_number_local enforces 256-window from execution context" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var hashes: [258]Hash.Hash = undefined;
    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    hashes[0] = genesis.hash;

    var parent_hash = genesis.hash;
    var i: u64 = 1;
    while (i < hashes.len) : (i += 1) {
        var hdr = primitives.BlockHeader.init();
        hdr.number = i;
        hdr.parent_hash = parent_hash;
        hdr.timestamp = i;
        const blk = try Block.from(&hdr, &primitives.BlockBody.init(), allocator);
        try chain.putBlock(blk);
        hashes[i] = blk.hash;
        parent_hash = blk.hash;
    }

    const tip = hashes[257];
    const execution_number: u64 = 258;

    // Oldest in-range block for execution #258 is #2.
    const oldest = (try block_hash_by_number_local(&chain, tip, execution_number, 2)) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &hashes[2], &oldest);

    // #1 is 257 blocks back from execution context, out of range.
    try std.testing.expect((try block_hash_by_number_local(&chain, tip, execution_number, 1)) == null);
}

test "Chain - last_256_block_hashes_local returns MissingTipBlock when tip missing" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var out: [256]Hash.Hash = undefined;
    try std.testing.expectError(error.MissingTipBlock, last_256_block_hashes_local(&chain, Hash.ZERO, &out));
}

test "Chain - last_256_block_hashes_local returns increasing order and includes tip" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);

    var h2 = primitives.BlockHeader.init();
    h2.number = 2;
    h2.parent_hash = b1.hash;
    h2.timestamp = 2;
    const b2 = try Block.from(&h2, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b2);

    var out: [256]Hash.Hash = undefined;
    const hashes = try last_256_block_hashes_local(&chain, b2.hash, &out);

    try std.testing.expectEqual(@as(usize, 3), hashes.len);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hashes[0]);
    try std.testing.expectEqualSlices(u8, &b1.hash, &hashes[1]);
    try std.testing.expectEqualSlices(u8, &b2.hash, &hashes[2]);
}

test "Chain - last_256_block_hashes_local caps result at 256 hashes" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var hashes_by_number: [260]Hash.Hash = undefined;
    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    hashes_by_number[0] = genesis.hash;

    var parent_hash = genesis.hash;
    var i: u64 = 1;
    while (i < hashes_by_number.len) : (i += 1) {
        var header = primitives.BlockHeader.init();
        header.number = i;
        header.parent_hash = parent_hash;
        header.timestamp = i;
        const block = try Block.from(&header, &primitives.BlockBody.init(), allocator);
        try chain.putBlock(block);
        hashes_by_number[i] = block.hash;
        parent_hash = block.hash;
    }

    var out: [256]Hash.Hash = undefined;
    const hashes = try last_256_block_hashes_local(&chain, hashes_by_number[259], &out);

    try std.testing.expectEqual(@as(usize, 256), hashes.len);
    try std.testing.expectEqualSlices(u8, &hashes_by_number[4], &hashes[0]);
    try std.testing.expectEqualSlices(u8, &hashes_by_number[259], &hashes[255]);
}

test "Chain - last_256_block_hashes_local returns MissingAncestorBlock when ancestry missing" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    var orphan_header = primitives.BlockHeader.init();
    orphan_header.number = 42;
    orphan_header.parent_hash = [_]u8{0xAB} ** 32;
    orphan_header.timestamp = 42;
    const orphan = try Block.from(&orphan_header, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(orphan);

    var out: [256]Hash.Hash = undefined;
    try std.testing.expectError(error.MissingAncestorBlock, last_256_block_hashes_local(&chain, orphan.hash, &out));
}

test "Chain - last_256_block_hashes_local returns MalformedAncestorBlock on non-contiguous ancestry" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);

    var header = primitives.BlockHeader.init();
    header.number = 2;
    header.parent_hash = genesis.hash;
    header.timestamp = 2;
    const malformed = try Block.from(&header, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(malformed);

    var out: [256]Hash.Hash = undefined;
    try std.testing.expectError(error.MalformedAncestorBlock, last_256_block_hashes_local(&chain, malformed.hash, &out));
}
