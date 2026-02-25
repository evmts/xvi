/// Sync manager primitives: sync mode bit flags (Nethermind-compatible shape).
///
/// Mirrors Nethermind's Synchronization.ParallelSync.SyncMode flags so that
/// higher-level coordination can be implemented idiomatically in Zig while
/// staying structurally aligned.
const std = @import("std");

/// Bitflag set representing current synchronization modes.
/// Multiple flags may be active at once.
pub const SyncMode = struct {
    pub const none: u32 = 0;

    /// We are connected and waiting for new blocks from peers (EL-driven).
    pub const waiting_for_block: u32 = 1 << 0; // WaitingForBlock
    /// We are not connected to usable peers.
    pub const disconnected: u32 = 1 << 1; // Disconnected

    /// Fast blocks umbrella flag.
    pub const fast_blocks: u32 = 1 << 2; // FastBlocks
    /// Standard fast sync (near head after fast blocks stage)
    pub const fast_sync: u32 = 1 << 3; // FastSync
    /// Downloading state trie nodes in fast sync.
    pub const state_nodes: u32 = 1 << 4; // StateNodes
    /// Full archive sync or full after state sync completes.
    pub const full: u32 = 1 << 5; // Full
    /// Loading blocks from local DB.
    pub const db_load: u32 = 1 << 7; // DbLoad (matches Nethermind gap at bit 6)

    /// Fast headers/body/receipts phases (piggybacking on fast_blocks).
    pub const fast_headers: u32 = fast_blocks | (1 << 8); // FastHeaders
    pub const fast_bodies: u32 = fast_blocks | (1 << 9); // FastBodies
    pub const fast_receipts: u32 = fast_blocks | (1 << 10); // FastReceipts

    /// Snap state sync (accounts/storage/code/proofs ranges).
    pub const snap_sync: u32 = 1 << 11; // SnapSync
    /// Reverse header download from beacon pivot to genesis.
    pub const beacon_headers: u32 = 1 << 12; // BeaconHeaders
    /// Waiting for forkchoice update to refresh pivot.
    pub const updating_pivot: u32 = 1 << 13; // UpdatingPivot

    pub const all: u32 = waiting_for_block | disconnected | fast_blocks | fast_sync | state_nodes |
        full | db_load | fast_headers | fast_bodies | fast_receipts | snap_sync | beacon_headers | updating_pivot;

    /// True when node is only waiting or disconnected (not actively syncing).
    /// Mirrors Nethermind's `SyncModeExtensions.NotSyncing` semantics.
    pub fn notSyncing(m: u32) bool {
        return m == waiting_for_block or m == disconnected;
    }

    /// True if block bodies are not yet fully synchronized.
    /// Mirrors Nethermind's `HaveNotSyncedBodiesYet` (mask membership).
    pub fn haveNotSyncedBodiesYet(m: u32) bool {
        const mask: u32 =
            fast_headers |
            fast_bodies |
            fast_sync |
            state_nodes |
            snap_sync |
            beacon_headers |
            updating_pivot;
        return (m & mask) != 0;
    }

    /// True if receipts are not yet fully synchronized.
    /// Mirrors Nethermind's `HaveNotSyncedReceiptsYet` (mask membership).
    pub fn haveNotSyncedReceiptsYet(m: u32) bool {
        const mask: u32 =
            fast_blocks |
            fast_sync |
            state_nodes |
            snap_sync |
            beacon_headers |
            updating_pivot;
        return (m & mask) != 0;
    }

    /// True if headers are not yet fully synchronized.
    /// Mirrors Nethermind's `HaveNotSyncedHeadersYet` (mask membership).
    pub fn haveNotSyncedHeadersYet(m: u32) bool {
        const mask: u32 =
            fast_headers |
            beacon_headers |
            updating_pivot;
        return (m & mask) != 0;
    }

    /// True if state (tries/snap) is not yet fully synchronized.
    /// Mirrors Nethermind's `HaveNotSyncedStateYet` (mask membership).
    pub fn haveNotSyncedStateYet(m: u32) bool {
        const mask: u32 =
            fast_sync |
            state_nodes |
            snap_sync |
            updating_pivot;
        return (m & mask) != 0;
    }
};

// Compile-time bit-layout parity guards (Nethermind SyncMode.cs).
comptime {
    // Base flags exact bit positions.
    if (SyncMode.waiting_for_block != (1 << 0)) @compileError("SyncMode.waiting_for_block must be bit 0");
    if (SyncMode.disconnected != (1 << 1)) @compileError("SyncMode.disconnected must be bit 1");
    if (SyncMode.fast_blocks != (1 << 2)) @compileError("SyncMode.fast_blocks must be bit 2");
    if (SyncMode.fast_sync != (1 << 3)) @compileError("SyncMode.fast_sync must be bit 3");
    if (SyncMode.state_nodes != (1 << 4)) @compileError("SyncMode.state_nodes must be bit 4");
    if (SyncMode.full != (1 << 5)) @compileError("SyncMode.full must be bit 5");
    // Bit 6 intentionally unused in Nethermind; keep gap.
    if ((SyncMode.all & (1 << 6)) != 0) @compileError("SyncMode bit 6 must remain unused for parity with Nethermind");
    if (SyncMode.db_load != (1 << 7)) @compileError("SyncMode.db_load must be bit 7");

    // Composed fast_* and higher bits.
    if (SyncMode.fast_headers != (SyncMode.fast_blocks | (1 << 8))) @compileError("SyncMode.fast_headers layout changed");
    if (SyncMode.fast_bodies != (SyncMode.fast_blocks | (1 << 9))) @compileError("SyncMode.fast_bodies layout changed");
    if (SyncMode.fast_receipts != (SyncMode.fast_blocks | (1 << 10))) @compileError("SyncMode.fast_receipts layout changed");
    if (SyncMode.snap_sync != (1 << 11)) @compileError("SyncMode.snap_sync must be bit 11");
    if (SyncMode.beacon_headers != (1 << 12)) @compileError("SyncMode.beacon_headers must be bit 12");
    if (SyncMode.updating_pivot != (1 << 13)) @compileError("SyncMode.updating_pivot must be bit 13");

    // all must include every declared flag and no extra bits.
    const expected_all: u32 =
        SyncMode.waiting_for_block | SyncMode.disconnected | SyncMode.fast_blocks | SyncMode.fast_sync |
        SyncMode.state_nodes | SyncMode.full | SyncMode.db_load | SyncMode.fast_headers | SyncMode.fast_bodies |
        SyncMode.fast_receipts | SyncMode.snap_sync | SyncMode.beacon_headers | SyncMode.updating_pivot;
    if (SyncMode.all != expected_all) @compileError("SyncMode.all must be the OR of all declared flags");
}

test "SyncMode bit flags uniqueness and composition" {
    // Ensure no overlap among base flags (excluding composed fast_* variants).
    const bases = [_]u32{
        SyncMode.waiting_for_block,
        SyncMode.disconnected,
        SyncMode.fast_blocks,
        SyncMode.fast_sync,
        SyncMode.state_nodes,
        SyncMode.full,
        SyncMode.db_load,
        SyncMode.snap_sync,
        SyncMode.beacon_headers,
        SyncMode.updating_pivot,
    };

    var acc: u32 = 0;
    for (bases) |b| {
        // No double-set bits.
        try std.testing.expect((acc & b) == 0);
        acc |= b;
    }

    // Composed fast_* include fast_blocks bit.
    try std.testing.expect((SyncMode.fast_headers & SyncMode.fast_blocks) != 0);
    try std.testing.expect((SyncMode.fast_bodies & SyncMode.fast_blocks) != 0);
    try std.testing.expect((SyncMode.fast_receipts & SyncMode.fast_blocks) != 0);

    // 'all' should include every named flag.
    try std.testing.expect((SyncMode.all & SyncMode.waiting_for_block) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.disconnected) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.fast_blocks) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.fast_sync) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.state_nodes) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.full) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.db_load) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.fast_headers) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.fast_bodies) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.fast_receipts) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.snap_sync) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.beacon_headers) != 0);
    try std.testing.expect((SyncMode.all & SyncMode.updating_pivot) != 0);
}

test "SyncMode helper predicates: notSyncing" {
    try std.testing.expect(SyncMode.notSyncing(SyncMode.waiting_for_block));
    try std.testing.expect(SyncMode.notSyncing(SyncMode.disconnected));
    try std.testing.expect(!SyncMode.notSyncing(SyncMode.fast_blocks));
    try std.testing.expect(!SyncMode.notSyncing(SyncMode.full));
}

test "SyncMode helper predicates: haveNotSyncedBodiesYet" {
    try std.testing.expect(SyncMode.haveNotSyncedBodiesYet(SyncMode.fast_headers));
    try std.testing.expect(SyncMode.haveNotSyncedBodiesYet(SyncMode.fast_bodies));
    try std.testing.expect(SyncMode.haveNotSyncedBodiesYet(SyncMode.fast_sync));
    try std.testing.expect(SyncMode.haveNotSyncedBodiesYet(SyncMode.state_nodes));
    try std.testing.expect(SyncMode.haveNotSyncedBodiesYet(SyncMode.snap_sync));
    try std.testing.expect(SyncMode.haveNotSyncedBodiesYet(SyncMode.beacon_headers));
    try std.testing.expect(SyncMode.haveNotSyncedBodiesYet(SyncMode.updating_pivot));
    try std.testing.expect(!SyncMode.haveNotSyncedBodiesYet(SyncMode.full));
    try std.testing.expect(!SyncMode.haveNotSyncedBodiesYet(SyncMode.db_load));
    try std.testing.expect(!SyncMode.haveNotSyncedBodiesYet(SyncMode.none));
}

test "SyncMode helper predicates: haveNotSyncedReceiptsYet" {
    try std.testing.expect(SyncMode.haveNotSyncedReceiptsYet(SyncMode.fast_blocks));
    try std.testing.expect(SyncMode.haveNotSyncedReceiptsYet(SyncMode.fast_receipts));
    try std.testing.expect(SyncMode.haveNotSyncedReceiptsYet(SyncMode.fast_sync));
    try std.testing.expect(SyncMode.haveNotSyncedReceiptsYet(SyncMode.state_nodes));
    try std.testing.expect(SyncMode.haveNotSyncedReceiptsYet(SyncMode.snap_sync));
    try std.testing.expect(SyncMode.haveNotSyncedReceiptsYet(SyncMode.beacon_headers));
    try std.testing.expect(SyncMode.haveNotSyncedReceiptsYet(SyncMode.updating_pivot));
    try std.testing.expect(!SyncMode.haveNotSyncedReceiptsYet(SyncMode.full));
    try std.testing.expect(!SyncMode.haveNotSyncedReceiptsYet(SyncMode.none));
}

test "SyncMode helper predicates: haveNotSyncedHeadersYet" {
    try std.testing.expect(SyncMode.haveNotSyncedHeadersYet(SyncMode.fast_headers));
    try std.testing.expect(SyncMode.haveNotSyncedHeadersYet(SyncMode.beacon_headers));
    try std.testing.expect(SyncMode.haveNotSyncedHeadersYet(SyncMode.updating_pivot));
    try std.testing.expect(!SyncMode.haveNotSyncedHeadersYet(SyncMode.full));
    try std.testing.expect(!SyncMode.haveNotSyncedHeadersYet(SyncMode.none));
}

test "SyncMode helper predicates: haveNotSyncedStateYet" {
    try std.testing.expect(SyncMode.haveNotSyncedStateYet(SyncMode.fast_sync));
    try std.testing.expect(SyncMode.haveNotSyncedStateYet(SyncMode.state_nodes));
    try std.testing.expect(SyncMode.haveNotSyncedStateYet(SyncMode.snap_sync));
    try std.testing.expect(SyncMode.haveNotSyncedStateYet(SyncMode.updating_pivot));
    try std.testing.expect(!SyncMode.haveNotSyncedStateYet(SyncMode.full));
    try std.testing.expect(!SyncMode.haveNotSyncedStateYet(SyncMode.none));
}
