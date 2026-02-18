/// In-memory database backend implementing the `Database` interface.
///
/// Modeled after Nethermind's `MemDb` (ConcurrentDictionary-backed), simplified
/// for single-threaded Zig. Uses a `std.HashMapUnmanaged` keyed by byte slices
/// with an arena allocator for all stored keys and values.
///
/// Tracks `reads_count` and `writes_count` for diagnostics, mirroring
/// Nethermind's `ReadsCount` / `WritesCount` properties.
///
/// ## Usage
///
/// ```zig
/// var db = MemoryDatabase.init(allocator, .state);
/// defer db.deinit();
///
/// const iface = db.database();
/// try iface.put("key", "value");
/// const view = try iface.get("key");
/// if (view) |val| {
///     defer val.release();
///     _ = val.bytes; // "value"
/// }
/// ```
const std = @import("std");
const primitives = @import("primitives");
const adapter = @import("adapter.zig");
const ByteSliceContext = @import("byte_slice_context.zig").ByteSliceContext;
const Database = adapter.Database;
const DbEntry = adapter.DbEntry;
const DbIterator = adapter.DbIterator;
const DbMetric = adapter.DbMetric;
const DbName = adapter.DbName;
const DbSnapshot = adapter.DbSnapshot;
const DbValue = adapter.DbValue;
const Error = adapter.Error;
const ReadFlags = adapter.ReadFlags;
const SortedView = adapter.SortedView;
const WriteFlags = adapter.WriteFlags;
const Bytes = primitives.Bytes;

/// Unmanaged HashMap type — allocator is passed explicitly to each operation,
/// avoiding the dangling-pointer problem when the containing struct is moved.
const Map = std.HashMapUnmanaged([]const u8, []const u8, ByteSliceContext, 80);

/// In-memory key-value database implementing the `Database` vtable interface.
///
/// All keys and values are copied into `arena` on `put`. On `delete` or
/// overwrite, old allocations remain in the arena and are freed together
/// when `deinit()` is called. This is consistent with the project's
/// arena-based allocation strategy (transaction-scoped memory).
pub const MemoryDatabase = struct {
    /// Underlying storage map (unmanaged — allocator passed per-call).
    map: Map = .{},
    /// Arena allocator that owns all stored key/value memory AND the map's
    /// internal table.
    arena: std.heap.ArenaAllocator,
    /// Backing allocator used for snapshot/iterator allocations.
    backing_allocator: std.mem.Allocator,
    /// Logical database name.
    name: DbName,
    /// Number of `get` / `contains` calls (read operations).
    reads_count: u64 = 0,
    /// Number of `put` / `delete` calls (write operations).
    writes_count: u64 = 0,

    /// Create a new empty MemoryDatabase backed by the given allocator.
    pub fn init(backing_allocator: std.mem.Allocator, name: DbName) MemoryDatabase {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .backing_allocator = backing_allocator,
            .name = name,
        };
    }

    /// Release all memory owned by this database (keys, values, hash map).
    pub fn deinit(self: *MemoryDatabase) void {
        // No need to deinit the map separately — all its memory is in the arena.
        self.arena.deinit();
    }

    /// Return the number of entries currently stored.
    fn count(self: *const MemoryDatabase) usize {
        return self.map.count();
    }

    /// Remove all entries and free accumulated memory.
    ///
    /// After `clear()`, the database is empty and reusable. The arena is
    /// reset (clearing stored keys/values while retaining capacity), and the
    /// map is re-initialized to an empty state.
    ///
    /// Mirrors Nethermind's `MemDb.Clear()` which wipes the underlying
    /// ConcurrentDictionary. Used by `ReadOnlyDb.clear_temp_changes()` to
    /// discard temporary write-overlay data.
    pub fn clear(self: *MemoryDatabase) void {
        // Reset arena — frees all key/value copies and map internal tables.
        _ = self.arena.reset(.retain_capacity);
        // Re-initialize map to empty (its internal buffer was in the arena).
        self.map = .{};
        // Reset diagnostic counters (Nethermind does not reset these, but
        // for a clear/reuse cycle it makes sense to start fresh).
        self.reads_count = 0;
        self.writes_count = 0;
    }

    /// Return a `Database` vtable interface backed by this MemoryDatabase.
    pub fn database(self: *MemoryDatabase) Database {
        return Database.init(MemoryDatabase, self, .{
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
            .first_key = first_key_impl,
            .last_key = last_key_impl,
            .get_view_between = get_view_between_impl,
        });
    }

    // -- Direct (non-vtable) methods ------------------------------------------

    /// Retrieve the value for `key`, or `null` if not found.
    pub fn get(self: *MemoryDatabase, key: []const u8) ?DbValue {
        return self.get_with_flags(key, .none);
    }

    /// Retrieve the value for `key` with explicit read flags.
    pub fn get_with_flags(self: *MemoryDatabase, key: []const u8, flags: ReadFlags) ?DbValue {
        _ = flags;
        self.reads_count += 1;
        if (self.map.get(key)) |val| {
            return DbValue.borrowed(val);
        }
        return null;
    }

    /// Store a key-value pair. If `value` is `null`, behaves as `delete`.
    /// Copies both key and value into the arena.
    pub fn put(self: *MemoryDatabase, key: []const u8, value: ?[]const u8) Error!void {
        return self.put_with_flags(key, value, .none);
    }

    /// Store a key-value pair with explicit write flags.
    pub fn put_with_flags(self: *MemoryDatabase, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void {
        _ = flags;
        self.writes_count += 1;
        if (value) |val| {
            const alloc = self.arena.allocator();
            // Copy key and value into arena
            const owned_key = alloc.dupe(u8, key) catch return error.OutOfMemory;
            const owned_val = alloc.dupe(u8, val) catch return error.OutOfMemory;
            // Insert (overwrites any existing entry; old key/value stay in arena)
            self.map.put(alloc, owned_key, owned_val) catch return error.OutOfMemory;
        } else {
            // put(key, null) behaves as delete (Nethermind pattern)
            _ = self.map.remove(key);
        }
    }

    /// Remove the entry for `key`. No-op if the key does not exist.
    pub fn delete(self: *MemoryDatabase, key: []const u8) Error!void {
        return self.delete_with_flags(key, .none);
    }

    /// Remove the entry for `key` with explicit write flags.
    pub fn delete_with_flags(self: *MemoryDatabase, key: []const u8, flags: WriteFlags) Error!void {
        _ = flags;
        self.writes_count += 1;
        _ = self.map.remove(key);
    }

    /// Retrieve multiple values in a single batch (sequential lookup).
    ///
    /// Mirrors Nethermind's `MemDb.this[byte[][] keys]` which does
    /// `keys.Select(k => new KeyValuePair(k, _db.GetValueOrDefault(k))).ToArray()`.
    /// Increments `reads_count` by `keys.len`.
    pub fn multi_get(self: *MemoryDatabase, keys: []const []const u8, results: []?DbValue, flags: ReadFlags) Error!void {
        for (keys, 0..) |key, i| {
            results[i] = self.get_with_flags(key, flags);
        }
    }

    /// Check whether `key` exists in the database.
    pub fn contains(self: *MemoryDatabase, key: []const u8) bool {
        self.reads_count += 1;
        return self.map.contains(key);
    }

    // -- Iterators and snapshots ----------------------------------------------

    const MemoryIterator = struct {
        iter: Map.Iterator,
        allocator: std.mem.Allocator,

        fn next(self: *MemoryIterator) Error!?DbEntry {
            if (self.iter.next()) |entry| {
                return DbEntry{
                    .key = DbValue.borrowed(entry.key_ptr.*),
                    .value = DbValue.borrowed(entry.value_ptr.*),
                };
            }
            return null;
        }

        fn deinit(self: *MemoryIterator) void {
            self.allocator.destroy(self);
        }
    };

    const OrderedIterator = struct {
        entries: []DbEntry,
        index: usize = 0,
        allocator: std.mem.Allocator,

        fn next(self: *OrderedIterator) Error!?DbEntry {
            if (self.index >= self.entries.len) return null;
            const entry = self.entries[self.index];
            self.index += 1;
            return entry;
        }

        fn deinit(self: *OrderedIterator) void {
            self.allocator.free(self.entries);
            self.allocator.destroy(self);
        }
    };

    /// Sorted view over a range-filtered, sorted slice of `DbEntry` values.
    ///
    /// Mirrors Nethermind's `RocksdbSortedView` — provides cursor-style iteration
    /// over entries in lexicographic key order within a range.
    ///
    /// The entries slice is owned by this struct and freed on `deinit`.
    /// Entry key/value bytes are borrowed from the parent database's arena and
    /// must remain valid for the lifetime of this view.
    const MemorySortedView = struct {
        /// Sorted, range-filtered entries (owned by this view).
        entries: []DbEntry,
        /// Current position. When `started` is false and `started_before` is
        /// false, the first `move_next` call will return entries[0].
        index: usize = 0,
        /// Whether iteration has begun (first move_next or start_before called).
        started: bool = false,
        /// Whether `start_before` was called.
        started_before: bool = false,
        /// Allocator used to free `entries` and self.
        allocator: std.mem.Allocator,

        /// Seek to the position just before `value` in sorted order.
        ///
        /// Uses binary search to find the largest key ≤ `value`.
        /// Can only be called once, before iteration starts.
        /// Mirrors Nethermind's `RocksdbSortedView.StartBefore(value)` which
        /// calls `iterator.SeekForPrev(value)`.
        fn start_before(self: *MemorySortedView, value: []const u8) Error!bool {
            if (self.started) return error.InvalidState; // Already started

            if (self.entries.len == 0) return false;

            // Binary search: find the largest key ≤ value.
            // We search for the first key > value, then step back.
            var low: usize = 0;
            var high: usize = self.entries.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (Bytes.compare(self.entries[mid].key.bytes, value) <= 0) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            // `low` is now the index of the first key > value.
            // The largest key ≤ value is at `low - 1`.
            if (low == 0) {
                // All keys are > value — no position before value.
                // Nethermind: `_started = _iterator.Valid()` — stays false when
                // SeekForPrev finds nothing, so MoveNext falls back to SeekToFirst.
                // We mirror this by NOT setting `started` — next move_next will
                // start from entries[0].
                return false;
            }
            // Valid position found — mark as started.
            // Mirrors Nethermind: `return _started = _iterator.Valid()` → true.
            self.started = true;
            self.started_before = true;
            self.index = low - 1;
            return true;
        }

        /// Advance to the next entry. Returns null when exhausted.
        ///
        /// On first call (without `start_before`), returns the first entry.
        /// After `start_before`, the first `move_next` advances past the
        /// `start_before` position and returns the next entry.
        ///
        /// Mirrors Nethermind's `RocksdbSortedView.MoveNext()`.
        fn move_next(self: *MemorySortedView) Error!?DbEntry {
            if (!self.started) {
                // First call without start_before — seek to first entry.
                self.started = true;
                if (self.entries.len == 0) return null;
                self.index = 0;
                return self.entries[0];
            }

            if (self.started_before) {
                // First move_next after start_before: advance past the
                // start_before position.
                self.started_before = false;
                self.index += 1;
                if (self.index >= self.entries.len) return null;
                return self.entries[self.index];
            }

            // Subsequent calls: advance to next entry.
            self.index += 1;
            if (self.index >= self.entries.len) return null;
            return self.entries[self.index];
        }

        /// Release all resources held by this view.
        fn deinit_impl(self: *MemorySortedView) void {
            self.allocator.free(self.entries);
            self.allocator.destroy(self);
        }
    };

    fn make_iterator(self: *MemoryDatabase, ordered: bool) Error!DbIterator {
        if (ordered) {
            var list: std.ArrayListUnmanaged(DbEntry) = .{};
            errdefer list.deinit(self.backing_allocator);

            var it = self.map.iterator();
            while (it.next()) |entry| {
                try list.append(self.backing_allocator, .{
                    .key = DbValue.borrowed(entry.key_ptr.*),
                    .value = DbValue.borrowed(entry.value_ptr.*),
                });
            }

            const entries = try list.toOwnedSlice(self.backing_allocator);
            const less_than = struct {
                fn lt(_: void, a: DbEntry, b: DbEntry) bool {
                    return Bytes.compare(a.key.bytes, b.key.bytes) < 0;
                }
            }.lt;
            std.sort.heap(DbEntry, entries, {}, less_than);

            const ordered_iter = self.backing_allocator.create(OrderedIterator) catch return error.OutOfMemory;
            ordered_iter.* = .{
                .entries = entries,
                .allocator = self.backing_allocator,
            };
            return DbIterator.init(OrderedIterator, ordered_iter, OrderedIterator.next, OrderedIterator.deinit);
        }

        const iterator = self.map.iterator();
        const mem_iter = self.backing_allocator.create(MemoryIterator) catch return error.OutOfMemory;
        mem_iter.* = .{
            .iter = iterator,
            .allocator = self.backing_allocator,
        };
        return DbIterator.init(MemoryIterator, mem_iter, MemoryIterator.next, MemoryIterator.deinit);
    }

    const MemorySnapshot = struct {
        db: MemoryDatabase,
        allocator: std.mem.Allocator,

        fn init(source: *MemoryDatabase) Error!*MemorySnapshot {
            const allocator = source.backing_allocator;
            const snapshot_ptr = allocator.create(MemorySnapshot) catch return error.OutOfMemory;
            errdefer allocator.destroy(snapshot_ptr);

            snapshot_ptr.* = .{
                .db = try clone_database(source, allocator),
                .allocator = allocator,
            };
            return snapshot_ptr;
        }

        fn snapshot(self: *MemorySnapshot) DbSnapshot {
            return DbSnapshot.init(
                MemorySnapshot,
                self,
                snapshot_get,
                snapshot_contains,
                snapshot_iterator,
                snapshot_deinit,
            );
        }

        fn snapshot_get(self: *MemorySnapshot, key: []const u8, flags: ReadFlags) Error!?DbValue {
            return self.db.get_with_flags(key, flags);
        }

        fn snapshot_contains(self: *MemorySnapshot, key: []const u8) Error!bool {
            return self.db.contains(key);
        }

        fn snapshot_iterator(self: *MemorySnapshot, ordered: bool) Error!DbIterator {
            return make_iterator(&self.db, ordered);
        }

        fn snapshot_deinit(self: *MemorySnapshot) void {
            self.db.deinit();
            self.allocator.destroy(self);
        }
    };

    fn clone_database(source: *MemoryDatabase, allocator: std.mem.Allocator) Error!MemoryDatabase {
        var clone = MemoryDatabase.init(allocator, source.name);
        errdefer clone.deinit();

        var it = source.map.iterator();
        while (it.next()) |entry| {
            const alloc = clone.arena.allocator();
            const owned_key = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
            const owned_val = alloc.dupe(u8, entry.value_ptr.*) catch return error.OutOfMemory;
            clone.map.put(alloc, owned_key, owned_val) catch return error.OutOfMemory;
        }

        return clone;
    }

    // -- VTable implementation ------------------------------------------------

    fn name_impl(self: *MemoryDatabase) DbName {
        return self.name;
    }

    fn get_impl(self: *MemoryDatabase, key: []const u8, flags: ReadFlags) Error!?DbValue {
        return self.get_with_flags(key, flags);
    }

    fn put_impl(self: *MemoryDatabase, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void {
        return self.put_with_flags(key, value, flags);
    }

    fn delete_impl(self: *MemoryDatabase, key: []const u8, flags: WriteFlags) Error!void {
        return self.delete_with_flags(key, flags);
    }

    fn contains_impl(self: *MemoryDatabase, key: []const u8) Error!bool {
        return self.contains(key);
    }

    fn iterator_impl(self: *MemoryDatabase, ordered: bool) Error!DbIterator {
        return make_iterator(self, ordered);
    }

    fn snapshot_impl(self: *MemoryDatabase) Error!DbSnapshot {
        const snapshot = try MemorySnapshot.init(self);
        return snapshot.snapshot();
    }

    fn flush_impl(_: *MemoryDatabase, _: bool) Error!void {}

    fn clear_impl(self: *MemoryDatabase) Error!void {
        self.clear();
    }

    fn compact_impl(_: *MemoryDatabase) Error!void {}

    fn gather_metric_impl(self: *MemoryDatabase) Error!DbMetric {
        return .{
            .size = @intCast(self.map.count()),
            .total_reads = self.reads_count,
            .total_writes = self.writes_count,
        };
    }

    fn multi_get_impl(self: *MemoryDatabase, keys: []const []const u8, results: []?DbValue, flags: ReadFlags) Error!void {
        return self.multi_get(keys, results, flags);
    }

    /// Return the lexicographically smallest key, or null if empty.
    ///
    /// Collects all keys, finds the minimum via `Bytes.compare`.
    /// O(n) scan — acceptable for in-memory test/dev backend.
    /// Mirrors Nethermind's `ISortedKeyValueStore.FirstKey`.
    fn first_key_impl(self: *MemoryDatabase) Error!?DbValue {
        if (self.map.count() == 0) return null;

        var it = self.map.iterator();
        var min_key: []const u8 = undefined;
        var first = true;
        while (it.next()) |entry| {
            if (first or Bytes.compare(entry.key_ptr.*, min_key) < 0) {
                min_key = entry.key_ptr.*;
                first = false;
            }
        }
        return DbValue.borrowed(min_key);
    }

    /// Return the lexicographically largest key, or null if empty.
    ///
    /// Collects all keys, finds the maximum via `Bytes.compare`.
    /// O(n) scan — acceptable for in-memory test/dev backend.
    /// Mirrors Nethermind's `ISortedKeyValueStore.LastKey`.
    fn last_key_impl(self: *MemoryDatabase) Error!?DbValue {
        if (self.map.count() == 0) return null;

        var it = self.map.iterator();
        var max_key: []const u8 = undefined;
        var first = true;
        while (it.next()) |entry| {
            if (first or Bytes.compare(entry.key_ptr.*, max_key) > 0) {
                max_key = entry.key_ptr.*;
                first = false;
            }
        }
        return DbValue.borrowed(max_key);
    }

    /// Create a sorted view over `[first_inclusive, last_exclusive)`.
    ///
    /// Collects all entries, sorts by key, filters to the specified range,
    /// and returns a `MemorySortedView` as a type-erased `SortedView`.
    ///
    /// O(n log n) sort — acceptable for in-memory test/dev backend.
    /// Mirrors Nethermind's `ISortedKeyValueStore.GetViewBetween()`.
    fn get_view_between_impl(
        self: *MemoryDatabase,
        first_inclusive: []const u8,
        last_exclusive: []const u8,
    ) Error!SortedView {
        const allocator = self.backing_allocator;

        // Collect all entries in the range [first_inclusive, last_exclusive).
        var list: std.ArrayListUnmanaged(DbEntry) = .{};
        errdefer list.deinit(allocator);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            // Include if key >= first_inclusive AND key < last_exclusive
            if (Bytes.compare(key, first_inclusive) >= 0 and
                Bytes.compare(key, last_exclusive) < 0)
            {
                list.append(allocator, .{
                    .key = DbValue.borrowed(key),
                    .value = DbValue.borrowed(entry.value_ptr.*),
                }) catch return error.OutOfMemory;
            }
        }

        // Sort by key in lexicographic order.
        const entries = list.toOwnedSlice(allocator) catch return error.OutOfMemory;
        const less_than = struct {
            fn lt(_: void, a: DbEntry, b: DbEntry) bool {
                return Bytes.compare(a.key.bytes, b.key.bytes) < 0;
            }
        }.lt;
        std.sort.heap(DbEntry, entries, {}, less_than);

        // Allocate the MemorySortedView on the heap.
        const view_ptr = allocator.create(MemorySortedView) catch return error.OutOfMemory;
        errdefer allocator.destroy(view_ptr);

        view_ptr.* = .{
            .entries = entries,
            .allocator = allocator,
        };

        return SortedView.init(
            MemorySortedView,
            view_ptr,
            MemorySortedView.start_before,
            MemorySortedView.move_next,
            MemorySortedView.deinit_impl,
        );
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MemoryDatabase: put then get round-trip" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("hello", "world");
    const val = db.get("hello");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("world", val.?.bytes);
}

test "MemoryDatabase: get missing key returns null" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const val = db.get("nonexistent");
    try std.testing.expect(val == null);
}

test "MemoryDatabase: delete existing key" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("key", "value");
    try std.testing.expect(db.contains("key"));

    try db.delete("key");
    try std.testing.expect(db.get("key") == null);
    try std.testing.expect(!db.contains("key"));
}

test "MemoryDatabase: delete non-existing key is no-op" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    // Should not panic or error
    try db.delete("missing");
    try std.testing.expectEqual(@as(usize, 0), db.count());
}

test "MemoryDatabase: contains returns true/false correctly" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try std.testing.expect(!db.contains("key"));
    try db.put("key", "val");
    try std.testing.expect(db.contains("key"));
}

test "MemoryDatabase: put with null value behaves as delete" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("key", "value");
    try std.testing.expect(db.contains("key"));

    try db.put("key", null);
    try std.testing.expect(!db.contains("key"));
    try std.testing.expect(db.get("key") == null);
}

test "MemoryDatabase: get_with_flags and put_with_flags and delete_with_flags" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put_with_flags("key", "value", .none);
    const val = db.get_with_flags("key", .none).?;
    defer val.release();
    try std.testing.expectEqualStrings("value", val.bytes);

    try db.delete_with_flags("key", .none);
    try std.testing.expect(db.get("key") == null);
}

test "MemoryDatabase: overwrite existing key" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("key", "first");
    const first = db.get("key").?;
    defer first.release();
    try std.testing.expectEqualStrings("first", first.bytes);

    try db.put("key", "second");
    const second = db.get("key").?;
    defer second.release();
    try std.testing.expectEqualStrings("second", second.bytes);
}

test "MemoryDatabase: reads_count and writes_count tracking" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try std.testing.expectEqual(@as(u64, 0), db.reads_count);
    try std.testing.expectEqual(@as(u64, 0), db.writes_count);

    // Writes: put increments writes_count
    try db.put("a", "1");
    try db.put("b", "2");
    try std.testing.expectEqual(@as(u64, 2), db.writes_count);

    // Reads: get increments reads_count
    const get_a = db.get("a");
    if (get_a) |val| val.release();
    const get_b = db.get("b");
    if (get_b) |val| val.release();
    if (db.get("missing")) |val| {
        val.release();
    }
    try std.testing.expectEqual(@as(u64, 3), db.reads_count);

    // Reads: contains increments reads_count
    _ = db.contains("a");
    try std.testing.expectEqual(@as(u64, 4), db.reads_count);

    // Writes: delete increments writes_count
    try db.delete("a");
    try std.testing.expectEqual(@as(u64, 3), db.writes_count);

    // Writes: put(key, null) increments writes_count
    try db.put("b", null);
    try std.testing.expectEqual(@as(u64, 4), db.writes_count);
}

test "MemoryDatabase: count returns correct number of entries" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try std.testing.expectEqual(@as(usize, 0), db.count());

    try db.put("a", "1");
    try std.testing.expectEqual(@as(usize, 1), db.count());

    try db.put("b", "2");
    try std.testing.expectEqual(@as(usize, 2), db.count());

    try db.delete("a");
    try std.testing.expectEqual(@as(usize, 1), db.count());
}

test "MemoryDatabase: vtable interface dispatches correctly" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const iface = db.database();

    // put via vtable
    try iface.put("key", "value");
    // get via vtable
    const val = try iface.get("key");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("value", val.?.bytes);

    // contains via vtable
    const exists = try iface.contains("key");
    try std.testing.expect(exists);

    // delete via vtable
    try iface.delete("key");
    const after = try iface.get("key");
    try std.testing.expect(after == null);
}

test "MemoryDatabase: vtable put null deletes via interface" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const iface = db.database();

    try iface.put("key", "value");
    const before = try iface.get("key");
    try std.testing.expect(before != null);
    defer before.?.release();

    try iface.put("key", null);
    const after = try iface.get("key");
    try std.testing.expect(after == null);
}

test "MemoryDatabase: empty key and value" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    // Empty key
    try db.put("", "value");
    const val1 = db.get("").?;
    defer val1.release();
    try std.testing.expectEqualStrings("value", val1.bytes);

    // Empty value
    try db.put("key", "");
    const val2 = db.get("key").?;
    defer val2.release();
    try std.testing.expectEqualStrings("", val2.bytes);

    // Empty key + empty value
    try db.put("", "");
    const val3 = db.get("").?;
    defer val3.release();
    try std.testing.expectEqualStrings("", val3.bytes);
}

test "MemoryDatabase: binary keys and values" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const key = &[_]u8{ 0x00, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF };
    const val = &[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE };

    try db.put(key, val);
    const result = db.get(key);
    try std.testing.expect(result != null);
    defer result.?.release();
    try std.testing.expectEqualSlices(u8, val, result.?.bytes);
}

test "MemoryDatabase: deinit frees all memory (leak check)" {
    // std.testing.allocator detects leaks on deinit
    var db = MemoryDatabase.init(std.testing.allocator, .state);

    try db.put("key1", "value1");
    try db.put("key2", "value2");
    try db.put("key3", "value3");
    try db.delete("key2");
    try db.put("key1", "overwritten");

    // If deinit doesn't free properly, testing allocator will report a leak
    db.deinit();
}

test "MemoryDatabase: many entries" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    // Insert 100 entries
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch unreachable;
        try db.put(key, key); // value = key for simplicity
    }

    try std.testing.expectEqual(@as(usize, 100), db.count());

    // Verify a few entries
    const val0 = db.get("0").?;
    defer val0.release();
    try std.testing.expectEqualStrings("0", val0.bytes);
    const val50 = db.get("50").?;
    defer val50.release();
    try std.testing.expectEqualStrings("50", val50.bytes);
    const val99 = db.get("99").?;
    defer val99.release();
    try std.testing.expectEqualStrings("99", val99.bytes);
}

test "MemoryDatabase: clear removes all entries and resets counters" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("a", "1");
    try db.put("b", "2");
    try db.put("c", "3");
    const get_a = db.get("a");
    if (get_a) |val| val.release();
    const get_b = db.get("b");
    if (get_b) |val| val.release();

    try std.testing.expectEqual(@as(usize, 3), db.count());
    try std.testing.expectEqual(@as(u64, 2), db.reads_count);
    try std.testing.expectEqual(@as(u64, 3), db.writes_count);

    db.clear();

    try std.testing.expectEqual(@as(usize, 0), db.count());
    try std.testing.expectEqual(@as(u64, 0), db.reads_count);
    try std.testing.expectEqual(@as(u64, 0), db.writes_count);
    try std.testing.expect(db.get("a") == null);
    try std.testing.expect(db.get("b") == null);
    try std.testing.expect(db.get("c") == null);
}

test "MemoryDatabase: clear then reuse" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("old_key", "old_value");
    try std.testing.expectEqual(@as(usize, 1), db.count());

    db.clear();
    try std.testing.expectEqual(@as(usize, 0), db.count());

    // Database should be fully reusable after clear
    try db.put("new_key", "new_value");
    try std.testing.expectEqual(@as(usize, 1), db.count());
    const new_val = db.get("new_key").?;
    defer new_val.release();
    try std.testing.expectEqualStrings("new_value", new_val.bytes);
    try std.testing.expect(db.get("old_key") == null);
}

test "MemoryDatabase: database name is preserved" {
    var db = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db.deinit();

    const iface = db.database();
    try std.testing.expectEqual(DbName.receipts, iface.name());
}

test "MemoryDatabase: iterator yields entries (unordered)" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("a", "1");
    try db.put("b", "2");

    var it = try db.database().iterator(false);
    defer it.deinit();

    var seen: usize = 0;
    while (try it.next()) |entry| {
        defer entry.release();
        if (Bytes.equals(entry.key.bytes, "a")) {
            try std.testing.expectEqualStrings("1", entry.value.bytes);
            seen += 1;
        } else if (Bytes.equals(entry.key.bytes, "b")) {
            try std.testing.expectEqualStrings("2", entry.value.bytes);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "MemoryDatabase: iterator yields entries in order" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("b", "2");
    try db.put("a", "1");
    try db.put("c", "3");

    var it = try db.database().iterator(true);
    defer it.deinit();

    const first = (try it.next()).?;
    defer first.release();
    try std.testing.expectEqualStrings("a", first.key.bytes);

    const second = (try it.next()).?;
    defer second.release();
    try std.testing.expectEqualStrings("b", second.key.bytes);

    const third = (try it.next()).?;
    defer third.release();
    try std.testing.expectEqualStrings("c", third.key.bytes);

    try std.testing.expect((try it.next()) == null);
}

test "MemoryDatabase: snapshot isolates later writes" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("key", "old");

    var snap = try db.database().snapshot();
    defer snap.deinit();

    try db.put("key", "new");
    try db.put("other", "value");

    const view = (try snap.get("key", .none)).?;
    defer view.release();
    try std.testing.expectEqualStrings("old", view.bytes);
    try std.testing.expect((try snap.get("other", .none)) == null);

    try std.testing.expect(try snap.contains("key"));
    try std.testing.expect(!try snap.contains("other"));

    var it = try snap.iterator(false);
    defer it.deinit();

    var seen: usize = 0;
    while (try it.next()) |entry| {
        defer entry.release();
        if (Bytes.equals(entry.key.bytes, "key")) {
            try std.testing.expectEqualStrings("old", entry.value.bytes);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "MemoryDatabase: gather_metric reflects counters" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("a", "1");
    if (db.get("a")) |val| {
        val.release();
    }
    const metric = try db.database().gather_metric();
    try std.testing.expectEqual(@as(u64, 1), metric.total_reads);
    try std.testing.expectEqual(@as(u64, 1), metric.total_writes);
}

// -- multi_get tests ---------------------------------------------------------

test "MemoryDatabase: multi_get returns found and missing keys" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("a", "val_a");
    try db.put("c", "val_c");

    const keys = &[_][]const u8{ "a", "b", "c" };
    var results: [3]?DbValue = undefined;
    try db.multi_get(keys, &results, ReadFlags.none);

    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("val_a", results[0].?.bytes);
    try std.testing.expect(results[1] == null);
    try std.testing.expect(results[2] != null);
    try std.testing.expectEqualStrings("val_c", results[2].?.bytes);
}

test "MemoryDatabase: multi_get with empty keys slice" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const keys: []const []const u8 = &.{};
    var results: [0]?DbValue = .{};
    try db.multi_get(keys, &results, ReadFlags.none);
    // No crash, no errors — empty is a valid no-op.
}

test "MemoryDatabase: multi_get increments reads_count" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("x", "1");

    try std.testing.expectEqual(@as(u64, 0), db.reads_count);

    const keys = &[_][]const u8{ "x", "y", "z" };
    var results: [3]?DbValue = undefined;
    try db.multi_get(keys, &results, ReadFlags.none);

    // Each key lookup increments reads_count via get_with_flags.
    try std.testing.expectEqual(@as(u64, 3), db.reads_count);
}

test "MemoryDatabase: multi_get via vtable interface" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("key1", "value1");
    try db.put("key3", "value3");

    const iface = db.database();
    try std.testing.expect(iface.supports_multi_get());

    const keys = &[_][]const u8{ "key1", "key2", "key3" };
    var results: [3]?DbValue = undefined;
    try iface.multi_get(keys, &results);

    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("value1", results[0].?.bytes);
    try std.testing.expect(results[1] == null);
    try std.testing.expect(results[2] != null);
    try std.testing.expectEqualStrings("value3", results[2].?.bytes);
}

// -- MemorySortedView tests --------------------------------------------------

test "MemorySortedView: iterate all entries" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(DbEntry, 3);

    entries[0] = .{ .key = DbValue.borrowed("aaa"), .value = DbValue.borrowed("111") };
    entries[1] = .{ .key = DbValue.borrowed("bbb"), .value = DbValue.borrowed("222") };
    entries[2] = .{ .key = DbValue.borrowed("ccc"), .value = DbValue.borrowed("333") };

    const view_ptr = try alloc.create(MemoryDatabase.MemorySortedView);
    view_ptr.* = .{ .entries = entries, .allocator = alloc };
    var view = SortedView.init(MemoryDatabase.MemorySortedView, view_ptr, MemoryDatabase.MemorySortedView.start_before, MemoryDatabase.MemorySortedView.move_next, MemoryDatabase.MemorySortedView.deinit_impl);
    defer view.deinit();

    const first = (try view.move_next()).?;
    try std.testing.expectEqualStrings("aaa", first.key.bytes);
    try std.testing.expectEqualStrings("111", first.value.bytes);

    const second = (try view.move_next()).?;
    try std.testing.expectEqualStrings("bbb", second.key.bytes);

    const third = (try view.move_next()).?;
    try std.testing.expectEqualStrings("ccc", third.key.bytes);

    try std.testing.expect((try view.move_next()) == null);
}

test "MemorySortedView: start_before seeks correctly" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(DbEntry, 3);

    entries[0] = .{ .key = DbValue.borrowed("aaa"), .value = DbValue.borrowed("111") };
    entries[1] = .{ .key = DbValue.borrowed("bbb"), .value = DbValue.borrowed("222") };
    entries[2] = .{ .key = DbValue.borrowed("ccc"), .value = DbValue.borrowed("333") };

    const view_ptr = try alloc.create(MemoryDatabase.MemorySortedView);
    view_ptr.* = .{ .entries = entries, .allocator = alloc };
    var view = SortedView.init(MemoryDatabase.MemorySortedView, view_ptr, MemoryDatabase.MemorySortedView.start_before, MemoryDatabase.MemorySortedView.move_next, MemoryDatabase.MemorySortedView.deinit_impl);
    defer view.deinit();

    // start_before "bbb" should find "bbb" (largest key <= "bbb")
    const found = try view.start_before("bbb");
    try std.testing.expect(found);

    // move_next after start_before should advance past "bbb" to "ccc"
    const entry = (try view.move_next()).?;
    try std.testing.expectEqualStrings("ccc", entry.key.bytes);

    try std.testing.expect((try view.move_next()) == null);
}

test "MemorySortedView: deinit frees memory (leak check)" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(DbEntry, 2);

    entries[0] = .{ .key = DbValue.borrowed("a"), .value = DbValue.borrowed("1") };
    entries[1] = .{ .key = DbValue.borrowed("b"), .value = DbValue.borrowed("2") };

    const view_ptr = try alloc.create(MemoryDatabase.MemorySortedView);
    view_ptr.* = .{ .entries = entries, .allocator = alloc };
    var view = SortedView.init(MemoryDatabase.MemorySortedView, view_ptr, MemoryDatabase.MemorySortedView.start_before, MemoryDatabase.MemorySortedView.move_next, MemoryDatabase.MemorySortedView.deinit_impl);

    // If deinit doesn't free properly, testing allocator will report a leak
    view.deinit();
}

test "MemorySortedView: empty entries returns null on move_next" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(DbEntry, 0);

    const view_ptr = try alloc.create(MemoryDatabase.MemorySortedView);
    view_ptr.* = .{ .entries = entries, .allocator = alloc };
    var view = SortedView.init(MemoryDatabase.MemorySortedView, view_ptr, MemoryDatabase.MemorySortedView.start_before, MemoryDatabase.MemorySortedView.move_next, MemoryDatabase.MemorySortedView.deinit_impl);
    defer view.deinit();

    try std.testing.expect((try view.move_next()) == null);
}

test "MemorySortedView: start_before with all keys greater returns false" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(DbEntry, 2);

    entries[0] = .{ .key = DbValue.borrowed("ddd"), .value = DbValue.borrowed("1") };
    entries[1] = .{ .key = DbValue.borrowed("eee"), .value = DbValue.borrowed("2") };

    const view_ptr = try alloc.create(MemoryDatabase.MemorySortedView);
    view_ptr.* = .{ .entries = entries, .allocator = alloc };
    var view = SortedView.init(MemoryDatabase.MemorySortedView, view_ptr, MemoryDatabase.MemorySortedView.start_before, MemoryDatabase.MemorySortedView.move_next, MemoryDatabase.MemorySortedView.deinit_impl);
    defer view.deinit();

    // "aaa" is less than all entries — start_before should return false
    const found = try view.start_before("aaa");
    try std.testing.expect(!found);
}

test "MemorySortedView: start_before(false) then move_next falls back to first entry (Nethermind parity)" {
    // Reproduces Nethermind behavior: when StartBefore returns false (_started stays false),
    // MoveNext falls back to SeekToFirst. This means start_before(false) + move_next should
    // return the first entry, not skip it.
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(DbEntry, 3);

    entries[0] = .{ .key = DbValue.borrowed("ddd"), .value = DbValue.borrowed("1") };
    entries[1] = .{ .key = DbValue.borrowed("eee"), .value = DbValue.borrowed("2") };
    entries[2] = .{ .key = DbValue.borrowed("fff"), .value = DbValue.borrowed("3") };

    const view_ptr = try alloc.create(MemoryDatabase.MemorySortedView);
    view_ptr.* = .{ .entries = entries, .allocator = alloc };
    var view = SortedView.init(MemoryDatabase.MemorySortedView, view_ptr, MemoryDatabase.MemorySortedView.start_before, MemoryDatabase.MemorySortedView.move_next, MemoryDatabase.MemorySortedView.deinit_impl);
    defer view.deinit();

    // start_before("aaa") — all keys > "aaa", so returns false
    const found = try view.start_before("aaa");
    try std.testing.expect(!found);

    // move_next should fall back to SeekToFirst — return "ddd"
    const first = (try view.move_next()).?;
    try std.testing.expectEqualStrings("ddd", first.key.bytes);

    // Continue iterating
    const second = (try view.move_next()).?;
    try std.testing.expectEqualStrings("eee", second.key.bytes);

    const third = (try view.move_next()).?;
    try std.testing.expectEqualStrings("fff", third.key.bytes);

    try std.testing.expect((try view.move_next()) == null);
}

test "MemorySortedView: move_next after exhaustion returns null" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(DbEntry, 1);
    entries[0] = .{ .key = DbValue.borrowed("aaa"), .value = DbValue.borrowed("111") };

    const view_ptr = try alloc.create(MemoryDatabase.MemorySortedView);
    view_ptr.* = .{ .entries = entries, .allocator = alloc };
    var view = SortedView.init(MemoryDatabase.MemorySortedView, view_ptr, MemoryDatabase.MemorySortedView.start_before, MemoryDatabase.MemorySortedView.move_next, MemoryDatabase.MemorySortedView.deinit_impl);
    defer view.deinit();

    _ = try view.move_next(); // First entry
    try std.testing.expect((try view.move_next()) == null); // Exhausted
    try std.testing.expect((try view.move_next()) == null); // Still exhausted
}

// -- MemoryDatabase sorted view VTable tests ----------------------------------

test "MemoryDatabase: supports_sorted_view returns true" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const iface = db.database();
    try std.testing.expect(iface.supports_sorted_view());
}

test "MemoryDatabase: first_key on empty DB returns null" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const iface = db.database();
    const result = try iface.first_key();
    try std.testing.expect(result == null);
}

test "MemoryDatabase: first_key returns lexicographic minimum" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("ccc", "3");
    try db.put("aaa", "1");
    try db.put("bbb", "2");

    const iface = db.database();
    const result = (try iface.first_key()).?;
    try std.testing.expectEqualStrings("aaa", result.bytes);
}

test "MemoryDatabase: last_key on empty DB returns null" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const iface = db.database();
    const result = try iface.last_key();
    try std.testing.expect(result == null);
}

test "MemoryDatabase: last_key returns lexicographic maximum" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("aaa", "1");
    try db.put("ccc", "3");
    try db.put("bbb", "2");

    const iface = db.database();
    const result = (try iface.last_key()).?;
    try std.testing.expectEqualStrings("ccc", result.bytes);
}

test "MemoryDatabase: get_view_between full range returns all entries in order" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("bbb", "2");
    try db.put("aaa", "1");
    try db.put("ccc", "3");

    const iface = db.database();
    // Range ["\x00", "\xff"] should include all entries
    var view = try iface.get_view_between(&[_]u8{0x00}, &[_]u8{0xFF});
    defer view.deinit();

    const first = (try view.move_next()).?;
    try std.testing.expectEqualStrings("aaa", first.key.bytes);
    try std.testing.expectEqualStrings("1", first.value.bytes);

    const second = (try view.move_next()).?;
    try std.testing.expectEqualStrings("bbb", second.key.bytes);
    try std.testing.expectEqualStrings("2", second.value.bytes);

    const third = (try view.move_next()).?;
    try std.testing.expectEqualStrings("ccc", third.key.bytes);
    try std.testing.expectEqualStrings("3", third.value.bytes);

    try std.testing.expect((try view.move_next()) == null);
}

test "MemoryDatabase: get_view_between partial range returns correct subset" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("aaa", "1");
    try db.put("bbb", "2");
    try db.put("ccc", "3");
    try db.put("ddd", "4");

    const iface = db.database();
    // Range ["bbb", "ddd") should include bbb and ccc only
    var view = try iface.get_view_between("bbb", "ddd");
    defer view.deinit();

    const first = (try view.move_next()).?;
    try std.testing.expectEqualStrings("bbb", first.key.bytes);

    const second = (try view.move_next()).?;
    try std.testing.expectEqualStrings("ccc", second.key.bytes);

    try std.testing.expect((try view.move_next()) == null);
}

test "MemoryDatabase: get_view_between empty range returns no entries" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("aaa", "1");
    try db.put("bbb", "2");

    const iface = db.database();
    // Range ["xxx", "yyy") includes nothing
    var view = try iface.get_view_between("xxx", "yyy");
    defer view.deinit();

    try std.testing.expect((try view.move_next()) == null);
}

test "MemoryDatabase: get_view_between single-entry range" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("aaa", "1");
    try db.put("bbb", "2");
    try db.put("ccc", "3");

    const iface = db.database();
    // Range ["bbb", "ccc") should include only bbb
    var view = try iface.get_view_between("bbb", "ccc");
    defer view.deinit();

    const entry = (try view.move_next()).?;
    try std.testing.expectEqualStrings("bbb", entry.key.bytes);

    try std.testing.expect((try view.move_next()) == null);
}

test "MemoryDatabase: get_view_between on empty database" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const iface = db.database();
    var view = try iface.get_view_between(&[_]u8{0}, &[_]u8{0xFF});
    defer view.deinit();

    try std.testing.expect((try view.move_next()) == null);
}

// -- Integration tests (Nethermind parity) ------------------------------------

test "MemoryDatabase: sorted view iterates entries in order (Nethermind IteratorWorks parity)" {
    // Reproduces Nethermind's DbOnTheRocksTests.IteratorWorks() test:
    // - Insert 3 entries: [0,0,0], [1,1,1], [2,2,2]
    // - Verify FirstKey == [0,0,0], LastKey == [2,2,2]
    // - GetViewBetween([0], [9]) iterates all 3 entries in order
    // - GetViewBetween([1], [2]) iterates only [1,1,1]
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    const entry_count: u8 = 3;
    var i: u8 = 0;
    while (i < entry_count) : (i += 1) {
        try db.put(&[_]u8{ i, i, i }, &[_]u8{ i, i, i });
    }

    const iface = db.database();

    // Verify FirstKey == [0,0,0]
    const first_key = (try iface.first_key()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0 }, first_key.bytes);

    // Verify LastKey == [2,2,2]
    const last_key = (try iface.last_key()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 2, 2 }, last_key.bytes);

    // GetViewBetween([0], [9]) should iterate all 3 entries in order
    {
        var view = try iface.get_view_between(&[_]u8{0}, &[_]u8{9});
        defer view.deinit();

        i = 0;
        while (try view.move_next()) |entry| {
            try std.testing.expectEqualSlices(u8, &[_]u8{ i, i, i }, entry.key.bytes);
            try std.testing.expectEqualSlices(u8, &[_]u8{ i, i, i }, entry.value.bytes);
            i += 1;
        }
        try std.testing.expectEqual(@as(u8, entry_count), i);
    }

    // GetViewBetween([1], [2]) should iterate only [1,1,1]
    {
        var view = try iface.get_view_between(&[_]u8{1}, &[_]u8{2});
        defer view.deinit();

        const entry = (try view.move_next()).?;
        try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1 }, entry.key.bytes);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1 }, entry.value.bytes);

        try std.testing.expect((try view.move_next()) == null);
    }
}

test "MemoryDatabase: sorted view with binary keys of various lengths" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put(&[_]u8{0x01}, "short_key");
    try db.put(&[_]u8{ 0x01, 0x02 }, "medium_key");
    try db.put(&[_]u8{ 0x01, 0x02, 0x03 }, "long_key");

    const iface = db.database();

    // Verify sorted order: shorter keys come first in lexicographic order
    var view = try iface.get_view_between(&[_]u8{0x00}, &[_]u8{0xFF});
    defer view.deinit();

    const first = (try view.move_next()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, first.key.bytes);

    const second = (try view.move_next()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, second.key.bytes);

    const third = (try view.move_next()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, third.key.bytes);

    try std.testing.expect((try view.move_next()) == null);
}

test "MemoryDatabase: multiple sorted views from same database are independent" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put("aaa", "1");
    try db.put("bbb", "2");
    try db.put("ccc", "3");

    const iface = db.database();

    var view1 = try iface.get_view_between("aaa", "zzz");
    defer view1.deinit();

    var view2 = try iface.get_view_between("bbb", "zzz");
    defer view2.deinit();

    // view1 starts at "aaa"
    const v1_first = (try view1.move_next()).?;
    try std.testing.expectEqualStrings("aaa", v1_first.key.bytes);

    // view2 starts at "bbb" (independent cursor)
    const v2_first = (try view2.move_next()).?;
    try std.testing.expectEqualStrings("bbb", v2_first.key.bytes);

    // view1 continues to "bbb"
    const v1_second = (try view1.move_next()).?;
    try std.testing.expectEqualStrings("bbb", v1_second.key.bytes);

    // view2 continues to "ccc"
    const v2_second = (try view2.move_next()).?;
    try std.testing.expectEqualStrings("ccc", v2_second.key.bytes);
}

test "MemoryDatabase: sorted view start_before semantics" {
    var db = MemoryDatabase.init(std.testing.allocator, .state);
    defer db.deinit();

    try db.put(&[_]u8{ 0, 0, 0 }, "zero");
    try db.put(&[_]u8{ 1, 1, 1 }, "one");
    try db.put(&[_]u8{ 2, 2, 2 }, "two");

    const iface = db.database();

    var view = try iface.get_view_between(&[_]u8{0}, &[_]u8{9});
    defer view.deinit();

    // start_before [1,1,1] should position at [1,1,1]
    const found = try view.start_before(&[_]u8{ 1, 1, 1 });
    try std.testing.expect(found);

    // move_next should advance past [1,1,1] to [2,2,2]
    const entry = (try view.move_next()).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 2, 2 }, entry.key.bytes);

    try std.testing.expect((try view.move_next()) == null);
}
