/// Sync manager startup planner (Nethermind Synchronizer.Start parity).
///
/// This module captures the startup feed activation rules from Nethermind's
/// `Synchronizer.Start*` methods as a small, allocation-free function.
const std = @import("std");

/// Subset of sync configuration used to decide which feeds are started.
pub const SyncManagerStartConfig = struct {
    /// Global synchronization enable switch.
    synchronization_enabled: bool = true,
    /// Enable fast-sync stages.
    fast_sync: bool = false,
    /// Enable snap sync stage (only considered when fast sync is enabled).
    snap_sync: bool = false,
    /// Enable fast header download stage.
    download_headers_in_fast_sync: bool = true,
    /// Enable fast block body download stage.
    download_bodies_in_fast_sync: bool = true,
    /// Enable fast receipts download stage.
    download_receipts_in_fast_sync: bool = true,
};

/// Startup feed bit flags produced by `startup_feed_mask`.
pub const SyncStartupFeed = struct {
    pub const none: u32 = 0;
    pub const full: u32 = 1 << 0;
    pub const fast_blocks: u32 = 1 << 1;
    pub const fast_state: u32 = 1 << 2;
    pub const snap: u32 = 1 << 3;
    pub const fast_headers: u32 = 1 << 4;
    pub const fast_bodies: u32 = 1 << 5;
    pub const fast_receipts: u32 = 1 << 6;
};

/// Compute the feed startup plan from sync configuration.
///
/// Mirrors Nethermind `Synchronizer.Start*`:
/// - If synchronization is disabled: start nothing.
/// - Always start full feed when synchronization is enabled.
/// - If fast-sync is enabled: start fast blocks feed + state feed.
/// - If snap-sync is enabled: start snap feed.
/// - Fast headers always start under fast-sync.
/// - Fast bodies/receipts start only when `download_headers_in_fast_sync`.
pub fn startup_feed_mask(config: SyncManagerStartConfig) u32 {
    if (!config.synchronization_enabled) return SyncStartupFeed.none;

    var mask: u32 = SyncStartupFeed.full;
    if (!config.fast_sync) return mask;

    mask |= SyncStartupFeed.fast_blocks | SyncStartupFeed.fast_state | SyncStartupFeed.fast_headers;

    if (config.snap_sync) {
        mask |= SyncStartupFeed.snap;
    }

    if (config.download_headers_in_fast_sync) {
        if (config.download_bodies_in_fast_sync) {
            mask |= SyncStartupFeed.fast_bodies;
        }
        if (config.download_receipts_in_fast_sync) {
            mask |= SyncStartupFeed.fast_receipts;
        }
    }

    return mask;
}

fn has_flag(mask: u32, flag: u32) bool {
    return (mask & flag) != 0;
}

test "startup_feed_mask: disabled synchronization starts no feeds" {
    const mask = startup_feed_mask(.{
        .synchronization_enabled = false,
        .fast_sync = true,
        .snap_sync = true,
    });
    try std.testing.expectEqual(SyncStartupFeed.none, mask);
}

test "startup_feed_mask: sync enabled without fast sync starts only full" {
    const mask = startup_feed_mask(.{
        .synchronization_enabled = true,
        .fast_sync = false,
        .snap_sync = true,
    });
    try std.testing.expectEqual(SyncStartupFeed.full, mask);
}

test "startup_feed_mask: fast sync starts full + fast blocks + state + headers" {
    const mask = startup_feed_mask(.{
        .synchronization_enabled = true,
        .fast_sync = true,
        .snap_sync = false,
        .download_headers_in_fast_sync = false,
        .download_bodies_in_fast_sync = true,
        .download_receipts_in_fast_sync = true,
    });

    try std.testing.expect(has_flag(mask, SyncStartupFeed.full));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.fast_blocks));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.fast_state));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.fast_headers));
    try std.testing.expect(!has_flag(mask, SyncStartupFeed.fast_bodies));
    try std.testing.expect(!has_flag(mask, SyncStartupFeed.fast_receipts));
    try std.testing.expect(!has_flag(mask, SyncStartupFeed.snap));
}

test "startup_feed_mask: snap and fast body/receipt feeds follow toggles" {
    const mask = startup_feed_mask(.{
        .synchronization_enabled = true,
        .fast_sync = true,
        .snap_sync = true,
        .download_headers_in_fast_sync = true,
        .download_bodies_in_fast_sync = true,
        .download_receipts_in_fast_sync = true,
    });

    try std.testing.expect(has_flag(mask, SyncStartupFeed.full));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.fast_blocks));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.fast_state));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.snap));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.fast_headers));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.fast_bodies));
    try std.testing.expect(has_flag(mask, SyncStartupFeed.fast_receipts));
}
