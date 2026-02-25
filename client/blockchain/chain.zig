/// Chain management aliases backed by Voltaire primitives.
const std = @import("std");
const blockchain = @import("blockchain");
const primitives = @import("voltaire");
const validator = @import("validator.zig");
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
/// - Resolves via the local canonical number->hash map (hash-only path), so
///   hot hash reads avoid full block fetch overhead.
/// - Race‑resilient snapshot: if the head changes during the read, a consistent
///   snapshot from the initial head number is returned rather than a stale mix.
pub fn head_hash(chain: *Chain) !?Hash.Hash {
    return head_hash_snapshot_local_with_policy(chain, 2);
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
    return head_block_of_with_policy(chain, 2);
}

/// Returns the pending block hash as the current canonical head hash (local-only).
///
/// Semantics:
/// - Mirrors Nethermind's `PendingHash` behavior where pending defaults to head.
/// - Uses only local head-number/canonical-hash snapshots; never fetches from
///   the fork cache and never allocates.
/// - Retries once when head changes during the read to avoid transient nulls.
pub fn pending_hash(chain: *Chain) ?Hash.Hash {
    return head_hash_snapshot_local_with_policy(chain, 2);
}

/// Returns the pending block resolved from `pending_hash` via finder semantics.
///
/// Semantics:
/// - Mirrors Nethermind's `FindPendingBlock` shape:
///   `PendingHash is null ? null : FindBlock(PendingHash, None)`.
/// - Resolves strictly from `pending_hash` to preserve `PendingHash = HeadHash`
///   semantics under snapshot races.
/// - Uses Voltaire's block finder path for hash->block resolution.
pub fn pending_block(chain: *Chain) !?Block.Block {
    const hash = pending_hash(chain) orelse return null;
    return try chain.getBlockByHash(hash);
}

fn head_hash_snapshot_local_with_policy(chain: *Chain, max_attempts: usize) ?Hash.Hash {
    const attempts = @max(max_attempts, 1);
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        const before = chain.getHeadBlockNumber() orelse return null;
        const maybe_hash = chain.getCanonicalHash(before);
        const hash = maybe_hash orelse {
            if (attempt + 1 == attempts) return null;
            continue;
        };
        const after = chain.getHeadBlockNumber() orelse return null;
        if (after == before) return hash;
        if (attempt + 1 == attempts) return hash; // return the "before" snapshot
    }
    return null; // defensive
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

/// Local-only safe head block lookup (no fork-cache fetch/allocations at this layer).
pub fn safe_head_block_of(chain: *Chain, fc: anytype) ?Block.Block {
    const h = fc.getSafeHash() orelse return null;
    return chain.getBlockLocal(h);
}

/// Local-only finalized head block lookup (no fork-cache fetch/allocations at this layer).
pub fn finalized_head_block_of(chain: *Chain, fc: anytype) ?Block.Block {
    const h = fc.getFinalizedHash() orelse return null;
    return chain.getBlockLocal(h);
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

    try std.testing.expect((try pending_block(&chain)) == null);
}

test "Chain - pending_block returns canonical head block" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    const block = (try pending_block(&chain)) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &genesis.hash, &block.hash);
    try std.testing.expectEqual(@as(u64, 0), block.header.number);
}

test "Chain - pending_block follows pending_hash across canonical head updates" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    var a1_header = primitives.BlockHeader.init();
    a1_header.number = 1;
    a1_header.parent_hash = genesis.hash;
    a1_header.timestamp = 1;
    const a1 = try Block.from(&a1_header, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(a1);
    try chain.setCanonicalHead(a1.hash);

    var b1_header = primitives.BlockHeader.init();
    b1_header.number = 1;
    b1_header.parent_hash = genesis.hash;
    b1_header.timestamp = 2;
    const b1 = try Block.from(&b1_header, &primitives.BlockBody.init(), allocator);
    try chain.putBlock(b1);
    try chain.setCanonicalHead(b1.hash);

    const p_hash = pending_hash(&chain) orelse return error.Unreachable;
    const p_block = (try pending_block(&chain)) orelse return error.Unreachable;
    try std.testing.expectEqualSlices(u8, &p_hash, &p_block.hash);
    try std.testing.expectEqualSlices(u8, &b1.hash, &p_hash);
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

test "Chain - generic head helpers are race-resilient" {
    const allocator = std.testing.allocator;
    var chain = try Chain.init(allocator, null);
    defer chain.deinit();

    const genesis = try Block.genesis(1, allocator);
    try chain.putBlock(genesis);
    try chain.setCanonicalHead(genesis.hash);

    // Snapshot helpers must return a consistent value
    const h1 = try head_hash_of_with_policy(&chain, 2);
    try std.testing.expect(h1 != null);
    const b1 = try head_block_of_with_policy(&chain, 2);
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

        const hh = try head_hash_of_with_policy(&mock_two_attempts, 2);
        try std.testing.expect(hh != null);
        try std.testing.expectEqualSlices(u8, &b1.hash, &hh.?);
    }
}

test "Chain - head_hash_of_with_policy clamps zero attempts to one" {
    const allocator = std.testing.allocator;
    const genesis = try Block.genesis(1, allocator);

    const MockHashOnlyChain = struct {
        head_number: ?u64 = 0,
        canonical_hash: Hash.Hash,

        pub fn getHeadBlockNumber(self: *@This()) ?u64 {
            return self.head_number;
        }

        pub fn getCanonicalHash(self: *@This(), number: u64) ?Hash.Hash {
            if (number != 0) return null;
            return self.canonical_hash;
        }
    };

    var mock = MockHashOnlyChain{ .canonical_hash = genesis.hash };
    const hh = try head_hash_of_with_policy(&mock, 0);
    try std.testing.expect(hh != null);
    try std.testing.expectEqualSlices(u8, &genesis.hash, &hh.?);
}

test "Chain - head_hash_of_with_policy applies retry semantics under head movement" {
    const allocator = std.testing.allocator;
    const genesis = try Block.genesis(1, allocator);

    var h1 = primitives.BlockHeader.init();
    h1.number = 1;
    h1.parent_hash = genesis.hash;
    h1.timestamp = 1;
    const b1 = try Block.from(&h1, &primitives.BlockBody.init(), allocator);

    const RacingHashChain = struct {
        head_number: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
        slow_first_lookup: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        first_hash: Hash.Hash,
        second_hash: Hash.Hash,

        pub fn getHeadBlockNumber(self: *@This()) ?u64 {
            return self.head_number.load(.acquire);
        }

        pub fn getCanonicalHash(self: *@This(), number: u64) ?Hash.Hash {
            if (number == 1 and self.slow_first_lookup.swap(false, .acq_rel)) {
                // Let the mover advance head between before/after reads.
                std.Thread.sleep(2 * std.time.ns_per_ms);
            }
            return switch (number) {
                1 => self.first_hash,
                2 => self.second_hash,
                else => null,
            };
        }

        pub fn moveHeadAfterDelay(self: *@This(), next_head: u64, delay_ns: u64) void {
            std.Thread.sleep(delay_ns);
            self.head_number.store(next_head, .release);
        }
    };

    // Single attempt returns the initial snapshot hash.
    {
        var mock_one = RacingHashChain{
            .first_hash = genesis.hash,
            .second_hash = b1.hash,
        };
        const mover = try std.Thread.spawn(.{}, RacingHashChain.moveHeadAfterDelay, .{
            &mock_one,
            @as(u64, 2),
            1 * std.time.ns_per_ms,
        });
        defer mover.join();

        const one = try head_hash_of_with_policy(&mock_one, 1);
        try std.testing.expect(one != null);
        try std.testing.expectEqualSlices(u8, &genesis.hash, &one.?);
    }

    // Two attempts should converge to the moved head hash.
    {
        var mock_two = RacingHashChain{
            .first_hash = genesis.hash,
            .second_hash = b1.hash,
        };
        const mover = try std.Thread.spawn(.{}, RacingHashChain.moveHeadAfterDelay, .{
            &mock_two,
            @as(u64, 2),
            1 * std.time.ns_per_ms,
        });
        defer mover.join();

        const two = try head_hash_of_with_policy(&mock_two, 2);
        try std.testing.expect(two != null);
        try std.testing.expectEqualSlices(u8, &b1.hash, &two.?);
    }
}

test "Chain - head_hash_of_with_policy uses canonical hash path when available" {
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
    const hh = try head_hash_of_with_policy(&mock, 2);
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

test "Chain - forkchoice getSafeHash forwards value" {
    var fc = TestForkchoice{ .safe = Hash.ZERO, .finalized = null };
    const h = fc.getSafeHash();
    try std.testing.expect(h != null);
    try std.testing.expectEqualSlices(u8, &Hash.ZERO, &h.?);
}

test "Chain - forkchoice getFinalizedHash forwards value" {
    var fc = TestForkchoice{ .safe = null, .finalized = Hash.ZERO };
    const h = fc.getFinalizedHash();
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
