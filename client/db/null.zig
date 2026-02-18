/// Null database backend implementing the `Database` interface.
///
/// Inspired by Nethermind's `NullDb` (`Nethermind.Db/NullDb.cs`) but with
/// a key behavioral difference on writes:
///   - All read operations return `null` / `false` (no data stored) — same as Nethermind.
///   - All write operations **silently discard** data (true null object pattern).
///     Nethermind's `NullDb` throws `NotSupportedException` on writes instead.
///   - `deinit()` is a no-op (no resources to release).
///
/// The silent-discard behavior was chosen (DB-001) so that NullDb can serve as
/// a drop-in stub in any context without callers needing write-error handling,
/// matching the classic Null Object pattern. Use `MemoryDatabase` if you need
/// actual in-memory storage, or implement a throwing variant if write rejection
/// is required.
///
/// For actual in-memory storage, use `MemoryDatabase` instead.
const std = @import("std");
const adapter = @import("adapter.zig");
const Database = adapter.Database;
const DbMetric = adapter.DbMetric;
const DbName = adapter.DbName;
const DbSnapshot = adapter.DbSnapshot;
const DbValue = adapter.DbValue;
const Error = adapter.Error;
const ReadFlags = adapter.ReadFlags;
const WriteFlags = adapter.WriteFlags;

/// Null database — satisfies the `Database` interface without storing data.
///
/// Inspired by Nethermind's `NullDb` singleton. In Zig we use a stack-allocated
/// struct instead of a singleton (no shared mutable state). Unlike Nethermind,
/// writes silently discard rather than throwing (see module-level docs).
///
/// ## Usage
///
/// ```zig
/// var ndb = NullDb.init(.state);
/// const iface = ndb.database();
/// const result = try iface.get("any_key"); // always null
/// ```
pub const NullDb = struct {
    name: DbName,

    /// Create a NullDb for the given logical database name.
    pub fn init(name: DbName) NullDb {
        return .{ .name = name };
    }

    /// Return a `Database` vtable interface backed by this NullDb.
    pub fn database(self: *NullDb) Database {
        return Database.init(NullDb, self, .{
            .name = name_impl,
            .get = get_impl,
            .put = put_impl,
            .delete = delete_impl,
            .contains = contains_impl,
            .iterator = iterator_impl,
            .snapshot = snapshot_impl,
            .flush = flush_impl,
            .clear = clear_impl,
            .compact = compact_impl,
            .gather_metric = gather_metric_impl,
            .multi_get = multi_get_impl,
        });
    }

    /// No-op — NullDb holds no resources.
    pub fn deinit(self: *NullDb) void {
        _ = self;
    }

    // -- VTable implementation (Null Object pattern) --------------------------

    fn name_impl(self: *NullDb) DbName {
        return self.name;
    }

    fn get_impl(_: *NullDb, _: []const u8, _: ReadFlags) Error!?DbValue {
        // Null database: no data stored, always returns null.
        return null;
    }

    fn put_impl(_: *NullDb, _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {
        // Null database: writes silently discarded (null object pattern).
    }

    fn delete_impl(_: *NullDb, _: []const u8, _: WriteFlags) Error!void {
        // Null database: deletes silently discarded (null object pattern).
    }

    fn contains_impl(_: *NullDb, _: []const u8) Error!bool {
        // Null database: no data stored, key never exists.
        return false;
    }

    const EmptyIterator = struct {
        fn next(_: *EmptyIterator) Error!?adapter.DbEntry {
            return null;
        }

        fn deinit(_: *EmptyIterator) void {}
    };

    fn iterator_impl(_: *NullDb, _: bool) Error!adapter.DbIterator {
        return adapter.DbIterator.init(
            EmptyIterator,
            &empty_iterator,
            EmptyIterator.next,
            EmptyIterator.deinit,
        );
    }

    const NullSnapshot = struct {
        fn snapshot_get(_: *NullSnapshot, _: []const u8, _: ReadFlags) Error!?DbValue {
            return null;
        }

        fn snapshot_contains(_: *NullSnapshot, _: []const u8) Error!bool {
            return false;
        }

        fn snapshot_iterator(_: *NullSnapshot, _: bool) Error!adapter.DbIterator {
            return adapter.DbIterator.init(
                EmptyIterator,
                &empty_iterator,
                EmptyIterator.next,
                EmptyIterator.deinit,
            );
        }

        fn snapshot_deinit(_: *NullSnapshot) void {}
    };

    fn snapshot_impl(_: *NullDb) Error!DbSnapshot {
        return DbSnapshot.init(
            NullSnapshot,
            &null_snapshot,
            NullSnapshot.snapshot_get,
            NullSnapshot.snapshot_contains,
            NullSnapshot.snapshot_iterator,
            NullSnapshot.snapshot_deinit,
        );
    }

    fn flush_impl(_: *NullDb, _: bool) Error!void {}

    fn clear_impl(_: *NullDb) Error!void {}

    fn compact_impl(_: *NullDb) Error!void {}

    fn gather_metric_impl(_: *NullDb) Error!DbMetric {
        return .{};
    }

    fn multi_get_impl(_: *NullDb, _: []const []const u8, results: []?DbValue, _: ReadFlags) Error!void {
        // Null database: no data stored, all results are null.
        for (results) |*r| {
            r.* = null;
        }
    }

    const empty_iterator = EmptyIterator{};
    const null_snapshot = NullSnapshot{};
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "NullDb: get always returns null" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();
    const result = try iface.get("any_key");
    try std.testing.expect(result == null);
}

test "NullDb: contains always returns false" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();
    const result = try iface.contains("any_key");
    try std.testing.expect(!result);
}

test "NullDb: put silently discards" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();
    try iface.put("key", "value");
    // Verify data was discarded — get still returns null.
    try std.testing.expect((try iface.get("key")) == null);
}

test "NullDb: put with null silently discards" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();
    try iface.put("key", null);
}

test "NullDb: delete silently discards" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();
    try iface.delete("key");
}

test "NullDb: multiple instances are independent" {
    var ndb1 = NullDb.init(.state);
    defer ndb1.deinit();

    var ndb2 = NullDb.init(.state);
    defer ndb2.deinit();

    const iface1 = ndb1.database();
    const iface2 = ndb2.database();

    try std.testing.expect((try iface1.get("key")) == null);
    try std.testing.expect((try iface2.get("key")) == null);
}

test "NullDb: name is accessible via interface" {
    var ndb = NullDb.init(.headers);
    defer ndb.deinit();

    const iface = ndb.database();
    try std.testing.expectEqual(DbName.headers, iface.name());
}

test "NullDb: iterator yields no entries" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();
    var it = try iface.iterator(false);
    defer it.deinit();

    try std.testing.expect((try it.next()) == null);
}

test "NullDb: snapshot returns null and empty iterator" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();
    var snap = try iface.snapshot();
    defer snap.deinit();

    try std.testing.expect((try snap.get("key", .none)) == null);
    try std.testing.expect(!try snap.contains("key"));

    var it = try snap.iterator(false);
    defer it.deinit();
    try std.testing.expect((try it.next()) == null);
}

test "NullDb: multi_get returns all nulls" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();
    try std.testing.expect(iface.supports_multi_get());

    const keys = &[_][]const u8{ "a", "b", "c" };
    var results: [3]?adapter.DbValue = undefined;
    try iface.multi_get(keys, &results);

    try std.testing.expect(results[0] == null);
    try std.testing.expect(results[1] == null);
    try std.testing.expect(results[2] == null);
}

test "NullDb: multi_get with empty keys slice" {
    var ndb = NullDb.init(.state);
    defer ndb.deinit();

    const iface = ndb.database();

    const keys: []const []const u8 = &.{};
    var results: [0]?adapter.DbValue = .{};
    try iface.multi_get(keys, &results);
    // No crash, no errors — empty is a valid no-op.
}
