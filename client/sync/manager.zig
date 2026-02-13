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
    /// Enable snap sync stage.
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
/// - If fast-sync or snap-sync is enabled: start fast blocks feed + state feed.
/// - If snap-sync is enabled: start snap feed.
/// - Fast headers always start under fast-sync.
/// - Fast bodies/receipts start only when `download_headers_in_fast_sync`.
pub fn startup_feed_mask(config: SyncManagerStartConfig) u32 {
    if (!config.synchronization_enabled) return SyncStartupFeed.none;

    var mask: u32 = SyncStartupFeed.full;
    const fast_sync_enabled = config.fast_sync or config.snap_sync;
    if (!fast_sync_enabled) return mask;

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

/// Comptime-injected sync manager coordinator.
///
/// `Feeds` must be a struct containing these fields:
/// - `full`
/// - `fast_blocks`
/// - `fast_state`
/// - `snap`
/// - `fast_headers`
/// - `fast_bodies`
/// - `fast_receipts`
///
/// Every feed field type must expose:
/// - `pub fn start(self: *Feed) void` OR
/// - `pub fn start(self: *Feed) !void`
///
/// Startup ordering mirrors Nethermind `Synchronizer.Start*` flow:
/// `full -> headers -> bodies -> receipts -> fast_blocks -> snap -> state`.
pub fn SyncManager(comptime Feeds: type) type {
    comptime validate_feeds_type(Feeds);

    return struct {
        const Self = @This();

        config: SyncManagerStartConfig,
        feeds: *Feeds,

        /// Start all enabled sync feeds and return the computed startup mask.
        ///
        /// Any feed start failure is returned to the caller; no errors are
        /// swallowed, and later feeds are not started after a failure.
        pub fn start(self: *Self) anyerror!u32 {
            const mask = startup_feed_mask(self.config);

            try start_feed_if_enabled(mask, SyncStartupFeed.full, &self.feeds.full);
            try start_feed_if_enabled(mask, SyncStartupFeed.fast_headers, &self.feeds.fast_headers);
            try start_feed_if_enabled(mask, SyncStartupFeed.fast_bodies, &self.feeds.fast_bodies);
            try start_feed_if_enabled(mask, SyncStartupFeed.fast_receipts, &self.feeds.fast_receipts);
            try start_feed_if_enabled(mask, SyncStartupFeed.fast_blocks, &self.feeds.fast_blocks);
            try start_feed_if_enabled(mask, SyncStartupFeed.snap, &self.feeds.snap);
            try start_feed_if_enabled(mask, SyncStartupFeed.fast_state, &self.feeds.fast_state);

            return mask;
        }
    };
}

fn validate_feeds_type(comptime Feeds: type) void {
    const feeds_info = @typeInfo(Feeds);
    if (feeds_info != .@"struct") {
        @compileError("SyncManager Feeds must be a struct type");
    }

    require_feed_field(Feeds, "full");
    require_feed_field(Feeds, "fast_blocks");
    require_feed_field(Feeds, "fast_state");
    require_feed_field(Feeds, "snap");
    require_feed_field(Feeds, "fast_headers");
    require_feed_field(Feeds, "fast_bodies");
    require_feed_field(Feeds, "fast_receipts");
}

fn require_feed_field(comptime Feeds: type, comptime field_name: []const u8) void {
    if (!@hasField(Feeds, field_name)) {
        @compileError("SyncManager Feeds is missing required field '" ++ field_name ++ "'");
    }
    const Feed = @FieldType(Feeds, field_name);
    require_feed_start_signature(Feed, field_name);
}

fn require_feed_start_signature(comptime Feed: type, comptime field_name: []const u8) void {
    if (!@hasDecl(Feed, "start")) {
        @compileError("SyncManager feed '" ++ field_name ++ "' must define start(self: *Feed) !void (or void)");
    }

    const fn_info = @typeInfo(@TypeOf(Feed.start));
    if (fn_info != .@"fn") {
        @compileError("SyncManager feed '" ++ field_name ++ "' start must be a function");
    }

    const start_fn = fn_info.@"fn";
    if (start_fn.params.len != 1 or start_fn.params[0].type == null) {
        @compileError("SyncManager feed '" ++ field_name ++ "' start must take one self pointer parameter");
    }

    const self_type = start_fn.params[0].type.?;
    const self_info = @typeInfo(self_type);
    if (self_info != .pointer or self_info.pointer.child != Feed) {
        @compileError("SyncManager feed '" ++ field_name ++ "' start(self: *Feed) has invalid self type");
    }

    const ret = start_fn.return_type orelse {
        @compileError("SyncManager feed '" ++ field_name ++ "' start must return void or !void");
    };

    if (ret == void) return;

    const ret_info = @typeInfo(ret);
    if (ret_info != .error_union or ret_info.error_union.payload != void) {
        @compileError("SyncManager feed '" ++ field_name ++ "' start must return void or !void");
    }
}

fn start_feed_if_enabled(mask: u32, flag: u32, feed_ptr: anytype) anyerror!void {
    if (!has_flag(mask, flag)) return;
    try call_feed_start(feed_ptr);
}

fn call_feed_start(feed_ptr: anytype) anyerror!void {
    const Feed = @typeInfo(@TypeOf(feed_ptr)).pointer.child;
    const start_ret = @typeInfo(@TypeOf(Feed.start)).@"fn".return_type.?;

    if (comptime start_ret == void) {
        Feed.start(feed_ptr);
        return;
    }

    try Feed.start(feed_ptr);
}

test "startup_feed_mask: disabled synchronization starts no feeds" {
    const mask = startup_feed_mask(.{
        .synchronization_enabled = false,
        .fast_sync = true,
        .snap_sync = true,
    });
    try std.testing.expectEqual(SyncStartupFeed.none, mask);
}

test "startup_feed_mask: snap sync implies fast-sync startup path" {
    const mask = startup_feed_mask(.{
        .synchronization_enabled = true,
        .fast_sync = false,
        .snap_sync = true,
    });
    try std.testing.expectEqual(@as(u32, SyncStartupFeed.full |
        SyncStartupFeed.fast_blocks |
        SyncStartupFeed.fast_state |
        SyncStartupFeed.fast_headers |
        SyncStartupFeed.snap |
        SyncStartupFeed.fast_bodies |
        SyncStartupFeed.fast_receipts), mask);
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

const FeedTrace = struct {
    order: [8]u8 = [_]u8{0} ** 8,
    len: usize = 0,

    fn push(self: *FeedTrace, id: u8) void {
        self.order[self.len] = id;
        self.len += 1;
    }
};

const TraceFeed = struct {
    trace: *FeedTrace,
    id: u8,
    starts: u8 = 0,
    fail: bool = false,

    pub const StartError = error{StartFailed};

    pub fn start(self: *@This()) StartError!void {
        self.starts += 1;
        self.trace.push(self.id);
        if (self.fail) return error.StartFailed;
    }
};

test "SyncManager.start: starts enabled feeds in Nethermind startup order" {
    const Feeds = struct {
        full: TraceFeed,
        fast_blocks: TraceFeed,
        fast_state: TraceFeed,
        snap: TraceFeed,
        fast_headers: TraceFeed,
        fast_bodies: TraceFeed,
        fast_receipts: TraceFeed,
    };
    const Manager = SyncManager(Feeds);

    var trace = FeedTrace{};
    var feeds = Feeds{
        .full = .{ .trace = &trace, .id = 1 },
        .fast_blocks = .{ .trace = &trace, .id = 5 },
        .fast_state = .{ .trace = &trace, .id = 7 },
        .snap = .{ .trace = &trace, .id = 6 },
        .fast_headers = .{ .trace = &trace, .id = 2 },
        .fast_bodies = .{ .trace = &trace, .id = 3 },
        .fast_receipts = .{ .trace = &trace, .id = 4 },
    };

    var manager = Manager{
        .config = .{
            .synchronization_enabled = true,
            .fast_sync = true,
            .snap_sync = true,
            .download_headers_in_fast_sync = true,
            .download_bodies_in_fast_sync = true,
            .download_receipts_in_fast_sync = true,
        },
        .feeds = &feeds,
    };

    const mask = try manager.start();
    const expected_order = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };

    try std.testing.expectEqual(@as(u32, SyncStartupFeed.full |
        SyncStartupFeed.fast_headers |
        SyncStartupFeed.fast_bodies |
        SyncStartupFeed.fast_receipts |
        SyncStartupFeed.fast_blocks |
        SyncStartupFeed.snap |
        SyncStartupFeed.fast_state), mask);
    try std.testing.expectEqualSlices(u8, &expected_order, trace.order[0..trace.len]);
    try std.testing.expectEqual(@as(u8, 1), feeds.full.starts);
    try std.testing.expectEqual(@as(u8, 1), feeds.fast_headers.starts);
    try std.testing.expectEqual(@as(u8, 1), feeds.fast_bodies.starts);
    try std.testing.expectEqual(@as(u8, 1), feeds.fast_receipts.starts);
    try std.testing.expectEqual(@as(u8, 1), feeds.fast_blocks.starts);
    try std.testing.expectEqual(@as(u8, 1), feeds.snap.starts);
    try std.testing.expectEqual(@as(u8, 1), feeds.fast_state.starts);
}

test "SyncManager.start: disabled synchronization starts no feed components" {
    const Feeds = struct {
        full: TraceFeed,
        fast_blocks: TraceFeed,
        fast_state: TraceFeed,
        snap: TraceFeed,
        fast_headers: TraceFeed,
        fast_bodies: TraceFeed,
        fast_receipts: TraceFeed,
    };
    const Manager = SyncManager(Feeds);

    var trace = FeedTrace{};
    var feeds = Feeds{
        .full = .{ .trace = &trace, .id = 1 },
        .fast_blocks = .{ .trace = &trace, .id = 5 },
        .fast_state = .{ .trace = &trace, .id = 7 },
        .snap = .{ .trace = &trace, .id = 6 },
        .fast_headers = .{ .trace = &trace, .id = 2 },
        .fast_bodies = .{ .trace = &trace, .id = 3 },
        .fast_receipts = .{ .trace = &trace, .id = 4 },
    };
    var manager = Manager{
        .config = .{
            .synchronization_enabled = false,
            .fast_sync = true,
            .snap_sync = true,
        },
        .feeds = &feeds,
    };

    const mask = try manager.start();
    try std.testing.expectEqual(SyncStartupFeed.none, mask);
    try std.testing.expectEqual(@as(usize, 0), trace.len);
    try std.testing.expectEqual(@as(u8, 0), feeds.full.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_headers.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_bodies.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_receipts.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_blocks.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.snap.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_state.starts);
}

test "SyncManager.start: propagates feed start errors and stops later startup" {
    const Feeds = struct {
        full: TraceFeed,
        fast_blocks: TraceFeed,
        fast_state: TraceFeed,
        snap: TraceFeed,
        fast_headers: TraceFeed,
        fast_bodies: TraceFeed,
        fast_receipts: TraceFeed,
    };
    const Manager = SyncManager(Feeds);

    var trace = FeedTrace{};
    var feeds = Feeds{
        .full = .{ .trace = &trace, .id = 1 },
        .fast_blocks = .{ .trace = &trace, .id = 5 },
        .fast_state = .{ .trace = &trace, .id = 7 },
        .snap = .{ .trace = &trace, .id = 6 },
        .fast_headers = .{ .trace = &trace, .id = 2, .fail = true },
        .fast_bodies = .{ .trace = &trace, .id = 3 },
        .fast_receipts = .{ .trace = &trace, .id = 4 },
    };

    var manager = Manager{
        .config = .{
            .synchronization_enabled = true,
            .fast_sync = true,
            .download_headers_in_fast_sync = true,
            .download_bodies_in_fast_sync = true,
            .download_receipts_in_fast_sync = true,
        },
        .feeds = &feeds,
    };

    try std.testing.expectError(TraceFeed.StartError.StartFailed, manager.start());
    const expected_order = [_]u8{ 1, 2 };
    try std.testing.expectEqualSlices(u8, &expected_order, trace.order[0..trace.len]);
    try std.testing.expectEqual(@as(u8, 1), feeds.full.starts);
    try std.testing.expectEqual(@as(u8, 1), feeds.fast_headers.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_bodies.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_receipts.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_blocks.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.snap.starts);
    try std.testing.expectEqual(@as(u8, 0), feeds.fast_state.starts);
}
