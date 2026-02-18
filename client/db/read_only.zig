/// Read-only database decorator implementing the `Database` interface.
///
/// Modeled after Nethermind's `ReadOnlyDb` (`Nethermind.Db/ReadOnlyDb.cs`):
/// wraps any `Database` and optionally provides an in-memory write overlay
/// (`MemoryDatabase`) for temporary changes during snapshot execution.
///
/// ## Modes
///
/// - **Strict read-only** (`init`): All writes return `error.StorageError`.
///   Reads delegate directly to the wrapped database.
///
/// - **Write overlay** (`init_with_write_store`): Writes go to an in-memory
///   overlay (`MemoryDatabase`). Reads check the overlay first, then fall
///   back to the wrapped database. Call `clear_temp_changes()` to discard all
///   overlay writes without affecting the wrapped database.
///
/// This matches Nethermind's `ReadOnlyDb(wrappedDb, createInMemWriteStore)`
/// constructor pattern and `ClearTempChanges()` method.
///
/// ## Intentional Divergences from Nethermind
///
/// 1. **Ordered iteration**: Nethermind's `ReadOnlyDb.GetAll(ordered)` ignores
///    the `ordered` parameter entirely, always returning unordered LINQ Union
///    results. This implementation provides a proper `MergeSortIterator` that
///    performs O(n+m) merge-sort when `ordered=true` is requested.
///
/// 2. **Content-based deduplication**: Nethermind's `.Union()` on
///    `KeyValuePair<byte[], byte[]>` uses reference equality for `byte[]`,
///    so duplicate keys from overlay and wrapped are not deduplicated. This
///    implementation performs content-based key comparison via `Bytes.compare()`
///    and gives overlay precedence, consistent with `get()` semantics.
///
/// 3. **Zero-allocation strict mode**: Nethermind always allocates a `MemDb`
///    regardless of `createInMemWriteStore`. This implementation only allocates
///    an overlay when `init_with_write_store` is called, making strict read-only
///    mode truly zero-allocation.
///
/// 4. **Sorted view delegation**: Nethermind's `ReadOnlyDb` does not implement
///    `ISortedKeyValueStore` at all. This implementation forwards `first_key`,
///    `last_key`, and `get_view_between` to the wrapped database, which is
///    correct for the wrapped-only data but does not account for overlay entries.
///    See sorted view method doc comments for details on this limitation.
///
/// ## Usage (strict read-only)
///
/// ```zig
/// var mem = MemoryDatabase.init(allocator, .state);
/// defer mem.deinit();
/// try mem.database().put("key", "value");
///
/// var ro = ReadOnlyDb.init(mem.database());
/// const iface = ro.database();
///
/// const view = try iface.get("key");
/// if (view) |val| {
///     defer val.release();
///     _ = val.bytes; // "value"
/// }
/// try iface.put("key", "new");          // error.StorageError
/// ```
///
/// ## Usage (write overlay for snapshot execution)
///
/// ```zig
/// var mem = MemoryDatabase.init(allocator, .state);
/// defer mem.deinit();
/// try mem.put("key", "original");
///
/// var ro = ReadOnlyDb.init_with_write_store(mem.database(), allocator);
/// defer ro.deinit();
/// const iface = ro.database();
///
/// try iface.put("key", "temp");          // writes to overlay only
/// const view = try iface.get("key");
/// if (view) |val| {
///     defer val.release();
///     _ = val.bytes; // "temp" (overlay wins)
/// }
/// ro.clear_temp_changes();               // discard overlay writes
/// const view2 = try iface.get("key");
/// if (view2) |val| {
///     defer val.release();
///     _ = val.bytes; // "original" (wrapped db)
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
const DbSnapshot = adapter.DbSnapshot;
const DbValue = adapter.DbValue;
const Error = adapter.Error;
const ReadFlags = adapter.ReadFlags;
const SortedView = adapter.SortedView;
const WriteFlags = adapter.WriteFlags;
const MemoryDatabase = @import("memory.zig").MemoryDatabase;
const Bytes = primitives.Bytes;

/// Read-only wrapper around any `Database` with optional in-memory write overlay.
///
/// Mirrors Nethermind's `ReadOnlyDb`:
/// - Reads: check overlay first (if present), then fall back to wrapped database.
/// - Writes: buffer in overlay if `create_in_mem_write_store` was set, else error.
/// - `clear_temp_changes()`: wipe overlay without touching wrapped database.
///
/// When `write_store` is null, the struct is zero-allocation (strict read-only mode).
/// When `write_store` is non-null, it owns the MemoryDatabase and frees it on `deinit`.
pub const ReadOnlyDb = struct {
    /// The underlying database to delegate reads to.
    wrapped: Database,
    /// Optional in-memory write overlay for temporary changes.
    /// Bundles the overlay database and its allocator together to prevent
    /// impossible states (overlay without allocator or vice versa).
    /// Mirrors Nethermind's `_memDb` field in `ReadOnlyDb.cs`.
    write_store: ?WriteStore,

    /// Owned overlay: an in-memory database and the allocator used to create it.
    const WriteStore = struct {
        db: *MemoryDatabase,
        allocator: std.mem.Allocator,
    };

    /// Create a strict read-only view over the given database (no write overlay).
    ///
    /// All write operations (put, delete) return `error.StorageError`.
    /// Equivalent to Nethermind's `ReadOnlyDb(wrappedDb, createInMemWriteStore: false)`.
    pub fn init(wrapped: Database) ReadOnlyDb {
        return .{
            .wrapped = wrapped,
            .write_store = null,
        };
    }

    /// Create a read-only view with an in-memory write overlay.
    ///
    /// Writes are buffered in the overlay and do not touch the wrapped database.
    /// Reads check the overlay first, then fall back to the wrapped database.
    /// Call `clear_temp_changes()` to discard all overlay writes.
    ///
    /// Equivalent to Nethermind's `ReadOnlyDb(wrappedDb, createInMemWriteStore: true)`.
    pub fn init_with_write_store(wrapped: Database, allocator: std.mem.Allocator) Error!ReadOnlyDb {
        const db = allocator.create(MemoryDatabase) catch return error.OutOfMemory;
        db.* = MemoryDatabase.init(allocator, wrapped.name());
        return .{
            .wrapped = wrapped,
            .write_store = .{ .db = db, .allocator = allocator },
        };
    }

    /// Release owned resources. If an overlay was created, frees it.
    pub fn deinit(self: *ReadOnlyDb) void {
        if (self.write_store) |ws| {
            ws.db.deinit();
            ws.allocator.destroy(ws.db);
            self.write_store = null;
        }
    }

    /// Return a `Database` vtable interface backed by this ReadOnlyDb.
    ///
    /// Sorted view operations (first_key, last_key, get_view_between) are
    /// forwarded to the wrapped database when it supports them. This mirrors
    /// Nethermind's `ColumnDb : ISortedKeyValueStore` which delegates sorted
    /// operations to the underlying RocksDB instance.
    pub fn database(self: *ReadOnlyDb) Database {
        return Database.init(ReadOnlyDb, self, .{
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

    /// Retrieve the value for `key`.
    ///
    /// If a write overlay is present, checks it first (overlay values take
    /// precedence). Falls back to the wrapped database if not found in overlay.
    /// Mirrors Nethermind's `_memDb.Get(key) ?? wrappedDb.Get(key)`.
    pub fn get(self: *ReadOnlyDb, key: []const u8) Error!?DbValue {
        return self.get_with_flags(key, .none);
    }

    /// Retrieve the value for `key` with explicit read flags.
    pub fn get_with_flags(self: *ReadOnlyDb, key: []const u8, flags: ReadFlags) Error!?DbValue {
        if (self.write_store) |ws| {
            if (ws.db.get_with_flags(key, flags)) |val| {
                return val;
            }
        }
        return self.wrapped.get_with_flags(key, flags);
    }

    /// Check whether `key` exists in the overlay or wrapped database.
    ///
    /// Mirrors Nethermind's `_memDb.KeyExists(key) || wrappedDb.KeyExists(key)`.
    pub fn contains(self: *ReadOnlyDb, key: []const u8) Error!bool {
        if (self.write_store) |ws| {
            if (ws.db.contains(key)) {
                return true;
            }
        }
        return self.wrapped.contains(key);
    }

    /// Discard all temporary writes in the overlay without affecting the
    /// wrapped database.
    ///
    /// No-op if no write overlay was created.
    /// Mirrors Nethermind's `ClearTempChanges()` which calls `_memDb.Clear()`.
    pub fn clear_temp_changes(self: *ReadOnlyDb) void {
        if (self.write_store) |ws| {
            ws.db.clear();
        }
    }

    /// Return whether this ReadOnlyDb has a write overlay enabled.
    pub fn has_write_overlay(self: *const ReadOnlyDb) bool {
        return self.write_store != null;
    }

    // -- Iterators and snapshots ----------------------------------------------

    const ReadOnlyIterator = struct {
        overlay_iter: DbIterator,
        wrapped_iter: DbIterator,
        seen: std.HashMapUnmanaged([]const u8, void, ByteSliceContext, 80) = .{},
        allocator: std.mem.Allocator,
        phase: Phase = .overlay,

        const Phase = enum { overlay, wrapped };

        fn next(self: *ReadOnlyIterator) Error!?DbEntry {
            while (true) {
                switch (self.phase) {
                    .overlay => {
                        const entry_opt = try self.overlay_iter.next();
                        if (entry_opt) |entry| {
                            self.seen.put(self.allocator, entry.key.bytes, {}) catch {
                                entry.release();
                                return error.OutOfMemory;
                            };
                            return entry;
                        }
                        self.phase = .wrapped;
                    },
                    .wrapped => {
                        const entry_opt = try self.wrapped_iter.next();
                        if (entry_opt) |entry| {
                            if (self.seen.contains(entry.key.bytes)) {
                                entry.release();
                                continue;
                            }
                            return entry;
                        }
                        return null;
                    },
                }
            }
        }

        fn deinit(self: *ReadOnlyIterator) void {
            self.overlay_iter.deinit();
            self.wrapped_iter.deinit();
            self.seen.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    };

    /// Merge-sort iterator that yields entries from both overlay and wrapped DB
    /// in lexicographic key order, deduplicating with overlay precedence.
    ///
    /// Both sub-iterators produce entries in sorted order. This performs an O(n+m)
    /// merge: it pre-fetches one entry from each sub-iterator and on each `next()`
    /// call yields the smaller key, advancing that sub-iterator. When keys are
    /// equal, the overlay entry wins (consistent with `get()` semantics and
    /// Nethermind's `.Union()` precedence) and the wrapped entry is released.
    ///
    /// Mirrors Nethermind's `ReadOnlyDb.GetAll()` which uses
    /// `_memDb.GetAll().Union(wrappedDb.GetAll())` — LINQ `Union` deduplicates
    /// with first-source precedence (memDb).
    const MergeSortIterator = struct {
        overlay_iter: DbIterator,
        wrapped_iter: DbIterator,
        overlay_current: ?DbEntry,
        wrapped_current: ?DbEntry,
        allocator: std.mem.Allocator,

        fn next(self: *MergeSortIterator) Error!?DbEntry {
            const ov = self.overlay_current;
            const wr = self.wrapped_current;

            if (ov) |ov_entry| {
                if (wr) |wr_entry| {
                    // Both have entries — compare keys.
                    const cmp = Bytes.compare(ov_entry.key.bytes, wr_entry.key.bytes);
                    if (cmp < 0) {
                        // Overlay key is smaller — yield overlay, advance overlay.
                        self.overlay_current = try self.overlay_iter.next();
                        return ov_entry;
                    } else if (cmp > 0) {
                        // Wrapped key is smaller — yield wrapped, advance wrapped.
                        self.wrapped_current = try self.wrapped_iter.next();
                        return wr_entry;
                    } else {
                        // Equal keys — overlay wins (precedence), release wrapped.
                        wr_entry.release();
                        self.overlay_current = try self.overlay_iter.next();
                        self.wrapped_current = try self.wrapped_iter.next();
                        return ov_entry;
                    }
                } else {
                    // Only overlay has an entry.
                    self.overlay_current = try self.overlay_iter.next();
                    return ov_entry;
                }
            } else if (wr) |wr_entry| {
                // Only wrapped has an entry.
                self.wrapped_current = try self.wrapped_iter.next();
                return wr_entry;
            }
            // Both exhausted.
            return null;
        }

        fn deinit(self: *MergeSortIterator) void {
            // Release any buffered entries that were pre-fetched but not yielded.
            if (self.overlay_current) |entry| entry.release();
            if (self.wrapped_current) |entry| entry.release();
            self.overlay_iter.deinit();
            self.wrapped_iter.deinit();
            self.allocator.destroy(self);
        }
    };

    const ReadOnlySnapshot = struct {
        wrapped: DbSnapshot,
        overlay: ?DbSnapshot,
        allocator: std.mem.Allocator,

        fn init(wrapped: DbSnapshot, overlay: ?DbSnapshot, allocator: std.mem.Allocator) Error!*ReadOnlySnapshot {
            const snapshot_ptr = allocator.create(ReadOnlySnapshot) catch return error.OutOfMemory;
            snapshot_ptr.* = .{
                .wrapped = wrapped,
                .overlay = overlay,
                .allocator = allocator,
            };
            return snapshot_ptr;
        }

        fn snapshot(self: *ReadOnlySnapshot) DbSnapshot {
            return DbSnapshot.init(
                ReadOnlySnapshot,
                self,
                snapshot_get,
                snapshot_contains,
                null,
                snapshot_deinit,
            );
        }

        fn snapshot_get(self: *ReadOnlySnapshot, key: []const u8, flags: ReadFlags) Error!?DbValue {
            if (self.overlay) |ov| {
                if (try ov.get(key, flags)) |val| {
                    return val;
                }
            }
            return self.wrapped.get(key, flags);
        }

        fn snapshot_contains(self: *ReadOnlySnapshot, key: []const u8) Error!bool {
            if (self.overlay) |ov| {
                if (try ov.contains(key)) {
                    return true;
                }
            }
            return self.wrapped.contains(key);
        }

        fn snapshot_deinit(self: *ReadOnlySnapshot) void {
            if (self.overlay) |*ov| {
                ov.deinit();
            }
            self.wrapped.deinit();
            self.allocator.destroy(self);
        }
    };

    // -- VTable implementation ------------------------------------------------

    fn name_impl(self: *ReadOnlyDb) adapter.DbName {
        return self.wrapped.name();
    }

    fn get_impl(self: *ReadOnlyDb, key: []const u8, flags: ReadFlags) Error!?DbValue {
        return self.get_with_flags(key, flags);
    }

    fn put_impl(self: *ReadOnlyDb, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void {
        if (self.write_store) |ws| {
            // Write to overlay only — never touches the wrapped database.
            // Mirrors Nethermind's `_memDb.Set(key, value, flags)`.
            return ws.db.put_with_flags(key, value, flags);
        }
        // No overlay — strict read-only mode, writes are not permitted.
        return error.StorageError;
    }

    fn delete_impl(self: *ReadOnlyDb, key: []const u8, flags: WriteFlags) Error!void {
        if (self.write_store) |ws| {
            // Delete from overlay only.
            return ws.db.delete_with_flags(key, flags);
        }
        // No overlay — strict read-only mode, deletes are not permitted.
        return error.StorageError;
    }

    fn contains_impl(self: *ReadOnlyDb, key: []const u8) Error!bool {
        return self.contains(key);
    }

    fn iterator_impl(self: *ReadOnlyDb, ordered: bool) Error!DbIterator {
        if (self.write_store) |ws| {
            if (ordered) {
                // Merge-sort: get ordered iterators from both sources, then
                // merge them in lexicographic key order with overlay precedence.
                // Mirrors Nethermind's `_memDb.GetAll().Union(wrappedDb.GetAll())`
                // but preserves key order via merge-sort instead of LINQ Union.
                var overlay_iter = try ws.db.database().iterator(true);
                errdefer overlay_iter.deinit();
                var wrapped_iter = try self.wrapped.iterator(true);
                errdefer wrapped_iter.deinit();

                // Pre-fetch first entry from each (lookahead for merge-sort).
                const overlay_first = try overlay_iter.next();
                const wrapped_first = try wrapped_iter.next();

                const ms_iter = ws.allocator.create(MergeSortIterator) catch return error.OutOfMemory;
                ms_iter.* = .{
                    .overlay_iter = overlay_iter,
                    .wrapped_iter = wrapped_iter,
                    .overlay_current = overlay_first,
                    .wrapped_current = wrapped_first,
                    .allocator = ws.allocator,
                };
                return DbIterator.init(MergeSortIterator, ms_iter, MergeSortIterator.next, MergeSortIterator.deinit);
            }
            // Unordered: existing ReadOnlyIterator (two-phase overlay-then-wrapped).
            var overlay_iter = try ws.db.database().iterator(false);
            errdefer overlay_iter.deinit();
            var wrapped_iter = try self.wrapped.iterator(false);
            errdefer wrapped_iter.deinit();

            const ro_iter = ws.allocator.create(ReadOnlyIterator) catch return error.OutOfMemory;
            ro_iter.* = .{
                .overlay_iter = overlay_iter,
                .wrapped_iter = wrapped_iter,
                .allocator = ws.allocator,
            };
            return DbIterator.init(ReadOnlyIterator, ro_iter, ReadOnlyIterator.next, ReadOnlyIterator.deinit);
        }
        return self.wrapped.iterator(ordered);
    }

    fn snapshot_impl(self: *ReadOnlyDb) Error!DbSnapshot {
        var wrapped_snapshot = try self.wrapped.snapshot();
        if (self.write_store) |ws| {
            errdefer wrapped_snapshot.deinit();
            var overlay_snapshot = try ws.db.database().snapshot();
            errdefer overlay_snapshot.deinit();
            const ro_snapshot = try ReadOnlySnapshot.init(wrapped_snapshot, overlay_snapshot, ws.allocator);
            return ro_snapshot.snapshot();
        }
        return wrapped_snapshot;
    }

    fn flush_impl(_: *ReadOnlyDb, _: bool) Error!void {}

    fn clear_impl(_: *ReadOnlyDb) Error!void {
        return error.UnsupportedOperation;
    }

    fn compact_impl(_: *ReadOnlyDb) Error!void {
        return error.UnsupportedOperation;
    }

    fn gather_metric_impl(self: *ReadOnlyDb) Error!DbMetric {
        return self.wrapped.gather_metric();
    }

    /// Forward first_key to the wrapped database.
    ///
    /// **Limitation:** This does NOT account for overlay entries. If the
    /// overlay contains a key that is lexicographically smaller than the
    /// wrapped database's first key, this method will still return the
    /// wrapped key. This is acceptable because:
    /// - Nethermind's `ReadOnlyDb` does not implement `ISortedKeyValueStore`
    ///   at all (only `DbOnTheRocks` does).
    /// - Sorted views are used for range scans over persistent storage (e.g.,
    ///   trie node enumeration), not over temporary overlay state.
    /// - Callers needing overlay-aware sorted iteration should use
    ///   `iterator(true)` which provides proper merge-sort over both sources.
    fn first_key_impl(self: *ReadOnlyDb) Error!?DbValue {
        return self.wrapped.first_key();
    }

    /// Forward last_key to the wrapped database.
    ///
    /// **Limitation:** Does NOT account for overlay entries. See
    /// `first_key_impl` for rationale.
    fn last_key_impl(self: *ReadOnlyDb) Error!?DbValue {
        return self.wrapped.last_key();
    }

    /// Forward get_view_between to the wrapped database.
    ///
    /// **Limitation:** Does NOT account for overlay entries. The returned
    /// view will only contain entries from the wrapped database within the
    /// specified key range. Overlay entries in that range are excluded.
    /// See `first_key_impl` for rationale. Use `iterator(true)` for
    /// overlay-aware ordered iteration over the full key space.
    fn get_view_between_impl(self: *ReadOnlyDb, first_inclusive: []const u8, last_exclusive: []const u8) Error!SortedView {
        return self.wrapped.get_view_between(first_inclusive, last_exclusive);
    }

    /// Stack-allocatable ceiling for the overlay miss-index buffer.
    /// Batches up to this size avoid heap allocation; larger batches
    /// fall back to the overlay allocator.
    const multi_get_stack_limit = 64;

    fn multi_get_impl(self: *ReadOnlyDb, keys: []const []const u8, results: []?DbValue, flags: ReadFlags) Error!void {
        if (self.write_store) |ws| {
            // Overlay merge pattern: check overlay first, collect misses,
            // then batch-fetch remaining keys from the wrapped database.
            // This preserves native MultiGet benefits (e.g., RocksDB batched I/O)
            // for keys not found in the overlay.

            // Stack buffer for small batches; heap fallback for large ones.
            var stack_indices: [multi_get_stack_limit]usize = undefined;
            var stack_keys: [multi_get_stack_limit][]const u8 = undefined;
            var stack_results: [multi_get_stack_limit]?DbValue = undefined;

            var miss_indices: []usize = undefined;
            var miss_keys: [][]const u8 = undefined;
            var miss_results: []?DbValue = undefined;
            var heap_allocated = false;

            if (keys.len <= multi_get_stack_limit) {
                miss_indices = stack_indices[0..keys.len];
                miss_keys = stack_keys[0..keys.len];
                miss_results = stack_results[0..keys.len];
            } else {
                miss_indices = ws.allocator.alloc(usize, keys.len) catch return error.OutOfMemory;
                miss_keys = ws.allocator.alloc([]const u8, keys.len) catch {
                    ws.allocator.free(miss_indices);
                    return error.OutOfMemory;
                };
                miss_results = ws.allocator.alloc(?DbValue, keys.len) catch {
                    ws.allocator.free(miss_keys);
                    ws.allocator.free(miss_indices);
                    return error.OutOfMemory;
                };
                heap_allocated = true;
            }
            defer if (heap_allocated) {
                ws.allocator.free(miss_results);
                ws.allocator.free(miss_keys);
                ws.allocator.free(miss_indices);
            };

            // Pass 1: check overlay, collect miss indices.
            var miss_count: usize = 0;
            for (keys, 0..) |key, i| {
                if (ws.db.get_with_flags(key, flags)) |val| {
                    results[i] = val;
                } else {
                    miss_indices[miss_count] = i;
                    miss_keys[miss_count] = key;
                    miss_count += 1;
                }
            }

            // Pass 2: batch-fetch misses from wrapped database.
            if (miss_count > 0) {
                try self.wrapped.multi_get_with_flags(
                    miss_keys[0..miss_count],
                    miss_results[0..miss_count],
                    flags,
                );
                // Scatter results back to original positions.
                for (0..miss_count) |j| {
                    results[miss_indices[j]] = miss_results[j];
                }
            }
        } else {
            // No overlay — delegate entirely to wrapped.
            // If wrapped supports multi_get, use it; otherwise sequential
            // fallback via Database.multi_get_with_flags.
            try self.wrapped.multi_get_with_flags(keys, results, flags);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests — Strict read-only mode (no overlay)
// ---------------------------------------------------------------------------

test "ReadOnlyDb: get delegates to wrapped database" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("hello", "world");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const val = try ro.get("hello");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("world", val.?.bytes);
}

test "ReadOnlyDb: get_with_flags delegates to wrapped database" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("hello", "world");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const val = try ro.get_with_flags("hello", .none);
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("world", val.?.bytes);
}

test "ReadOnlyDb: get missing key returns null" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const val = try ro.get("nonexistent");
    try std.testing.expect(val == null);
}

test "ReadOnlyDb: contains delegates to wrapped database" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "val");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    try std.testing.expect(try ro.contains("key"));
    try std.testing.expect(!try ro.contains("missing"));
}

test "ReadOnlyDb: put returns StorageError (no overlay)" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    try std.testing.expectError(error.StorageError, iface.put("key", "value"));
}

test "ReadOnlyDb: put with null returns StorageError (no overlay)" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    try std.testing.expectError(error.StorageError, iface.put("key", null));
}

test "ReadOnlyDb: delete returns StorageError (no overlay)" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    try std.testing.expectError(error.StorageError, iface.delete("key"));
}

test "ReadOnlyDb: vtable get dispatches correctly" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "value");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    const val = try iface.get("key");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("value", val.?.bytes);
}

test "ReadOnlyDb: vtable contains dispatches correctly" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "val");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    try std.testing.expect(try iface.contains("key"));
    try std.testing.expect(!try iface.contains("missing"));
}

test "ReadOnlyDb: reflects changes in underlying database" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    // Initially empty
    try std.testing.expect((try ro.get("key")) == null);

    // Write to underlying database directly
    try mem.put("key", "value");

    // Read-only view should see the new data
    const val = try ro.get("key");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("value", val.?.bytes);
}

test "ReadOnlyDb: does not modify underlying database on write attempts" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "original");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();

    // Attempt to overwrite — should fail
    try std.testing.expectError(error.StorageError, iface.put("key", "modified"));

    // Original value should be unchanged
    const original = mem.get("key").?;
    defer original.release();
    try std.testing.expectEqualStrings("original", original.bytes);

    // Attempt to delete — should fail
    try std.testing.expectError(error.StorageError, iface.delete("key"));

    // Original value still intact
    const still_original = mem.get("key").?;
    defer still_original.release();
    try std.testing.expectEqualStrings("original", still_original.bytes);
}

test "ReadOnlyDb: has_write_overlay is false without overlay" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    try std.testing.expect(!ro.has_write_overlay());
}

test "ReadOnlyDb: clear_temp_changes is no-op without overlay" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    // Should not panic or crash
    ro.clear_temp_changes();
}

// ---------------------------------------------------------------------------
// Tests — Write overlay mode (Nethermind ClearTempChanges pattern)
// ---------------------------------------------------------------------------

test "ReadOnlyDb: init_with_write_store enables overlay" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    try std.testing.expect(ro.has_write_overlay());
}

test "ReadOnlyDb: overlay put succeeds and get returns overlay value" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("base_key", "base_val");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();

    // Write to overlay
    try iface.put("new_key", "new_val");

    // Should find overlay value
    const val = try iface.get("new_key");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("new_val", val.?.bytes);

    // Should still find base value
    const base_val = try iface.get("base_key");
    try std.testing.expect(base_val != null);
    defer base_val.?.release();
    try std.testing.expectEqualStrings("base_val", base_val.?.bytes);
}

test "ReadOnlyDb: overlay value takes precedence over wrapped" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "original");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();

    // Overwrite in overlay
    try iface.put("key", "overlay_value");

    // Overlay wins
    const val = try iface.get("key");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("overlay_value", val.?.bytes);

    // Wrapped database is untouched
    const original = mem.get("key").?;
    defer original.release();
    try std.testing.expectEqualStrings("original", original.bytes);
}

test "ReadOnlyDb: clear_temp_changes discards overlay writes" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "original");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();

    // Write to overlay
    try iface.put("key", "temp_value");
    try iface.put("extra", "extra_val");

    // Verify overlay values are visible
    const temp_val = (try iface.get("key")).?;
    defer temp_val.release();
    try std.testing.expectEqualStrings("temp_value", temp_val.bytes);
    try std.testing.expect(try iface.contains("extra"));

    // Clear overlay
    ro.clear_temp_changes();

    // Overlay values are gone — falls back to wrapped
    const orig = (try iface.get("key")).?;
    defer orig.release();
    try std.testing.expectEqualStrings("original", orig.bytes);
    try std.testing.expect((try iface.get("extra")) == null);
    try std.testing.expect(!try iface.contains("extra"));
}

test "ReadOnlyDb: overlay delete does not affect wrapped database" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "value");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();

    // Write a key to overlay, then delete it
    try iface.put("overlay_key", "overlay_val");
    try iface.delete("overlay_key");

    // Overlay key is gone
    try std.testing.expect((try iface.get("overlay_key")) == null);

    // Wrapped database is untouched
    const wrapped_val = mem.get("key").?;
    defer wrapped_val.release();
    try std.testing.expectEqualStrings("value", wrapped_val.bytes);
}

test "ReadOnlyDb: contains checks overlay then wrapped" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("wrapped_key", "val");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();

    // Key only in wrapped
    try std.testing.expect(try iface.contains("wrapped_key"));

    // Key only in overlay
    try iface.put("overlay_key", "oval");
    try std.testing.expect(try iface.contains("overlay_key"));

    // Missing from both
    try std.testing.expect(!try iface.contains("missing"));
}

test "ReadOnlyDb: overlay reusable after clear_temp_changes" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();

    // First round of writes
    try iface.put("key1", "val1");
    const first = (try iface.get("key1")).?;
    defer first.release();
    try std.testing.expectEqualStrings("val1", first.bytes);

    // Clear
    ro.clear_temp_changes();
    try std.testing.expect((try iface.get("key1")) == null);

    // Second round of writes — overlay should work again
    try iface.put("key2", "val2");
    const second = (try iface.get("key2")).?;
    defer second.release();
    try std.testing.expectEqualStrings("val2", second.bytes);

    // Clear again
    ro.clear_temp_changes();
    try std.testing.expect((try iface.get("key2")) == null);
}

test "ReadOnlyDb: iterator merges overlay and wrapped without duplicates" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("a", "base_a");
    try mem.put("b", "base_b");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();
    try iface.put("b", "overlay_b");
    try iface.put("c", "overlay_c");

    var it = try iface.iterator(false);
    defer it.deinit();

    var seen_a = false;
    var seen_b = false;
    var seen_c = false;
    while (try it.next()) |entry| {
        defer entry.release();
        if (Bytes.equals(entry.key.bytes, "a")) {
            seen_a = true;
            try std.testing.expectEqualStrings("base_a", entry.value.bytes);
        } else if (Bytes.equals(entry.key.bytes, "b")) {
            seen_b = true;
            try std.testing.expectEqualStrings("overlay_b", entry.value.bytes);
        } else if (Bytes.equals(entry.key.bytes, "c")) {
            seen_c = true;
            try std.testing.expectEqualStrings("overlay_c", entry.value.bytes);
        }
    }

    try std.testing.expect(seen_a);
    try std.testing.expect(seen_b);
    try std.testing.expect(seen_c);
}

test "ReadOnlyDb: iterator ordered merges overlay and wrapped in key order" {
    // Setup: wrapped has {a, c}, overlay has {b, c_override}
    // Expected ordered output: a(wrapped), b(overlay), c(overlay_value)
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();
    try mem.put("a", "base_a");
    try mem.put("c", "base_c");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();
    const iface = ro.database();
    try iface.put("b", "overlay_b");
    try iface.put("c", "overlay_c"); // overlay overrides wrapped

    var it = try iface.iterator(true);
    defer it.deinit();

    // Entry 1: "a" from wrapped
    const e1 = (try it.next()).?;
    defer e1.release();
    try std.testing.expectEqualStrings("a", e1.key.bytes);
    try std.testing.expectEqualStrings("base_a", e1.value.bytes);

    // Entry 2: "b" from overlay
    const e2 = (try it.next()).?;
    defer e2.release();
    try std.testing.expectEqualStrings("b", e2.key.bytes);
    try std.testing.expectEqualStrings("overlay_b", e2.value.bytes);

    // Entry 3: "c" from overlay (precedence over wrapped)
    const e3 = (try it.next()).?;
    defer e3.release();
    try std.testing.expectEqualStrings("c", e3.key.bytes);
    try std.testing.expectEqualStrings("overlay_c", e3.value.bytes);

    // Exhausted
    try std.testing.expect((try it.next()) == null);
}

test "ReadOnlyDb: iterator ordered with empty overlay yields wrapped entries in order" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();
    try mem.put("b", "2");
    try mem.put("a", "1");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();
    // Overlay is empty — all entries come from wrapped

    var it = try ro.database().iterator(true);
    defer it.deinit();

    const e1 = (try it.next()).?;
    defer e1.release();
    try std.testing.expectEqualStrings("a", e1.key.bytes);

    const e2 = (try it.next()).?;
    defer e2.release();
    try std.testing.expectEqualStrings("b", e2.key.bytes);

    try std.testing.expect((try it.next()) == null);
}

test "ReadOnlyDb: iterator ordered with empty wrapped yields overlay entries in order" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();
    // Wrapped is empty

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();
    const iface = ro.database();
    try iface.put("z", "26");
    try iface.put("a", "1");

    var it = try iface.iterator(true);
    defer it.deinit();

    const e1 = (try it.next()).?;
    defer e1.release();
    try std.testing.expectEqualStrings("a", e1.key.bytes);

    const e2 = (try it.next()).?;
    defer e2.release();
    try std.testing.expectEqualStrings("z", e2.key.bytes);

    try std.testing.expect((try it.next()) == null);
}

test "ReadOnlyDb: iterator ordered with both empty returns null immediately" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    var it = try ro.database().iterator(true);
    defer it.deinit();

    try std.testing.expect((try it.next()) == null);
}

test "ReadOnlyDb: iterator ordered all duplicate keys yields overlay values" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();
    try mem.put("x", "wrapped_x");
    try mem.put("y", "wrapped_y");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();
    const iface = ro.database();
    try iface.put("x", "overlay_x");
    try iface.put("y", "overlay_y");

    var it = try iface.iterator(true);
    defer it.deinit();

    const e1 = (try it.next()).?;
    defer e1.release();
    try std.testing.expectEqualStrings("x", e1.key.bytes);
    try std.testing.expectEqualStrings("overlay_x", e1.value.bytes);

    const e2 = (try it.next()).?;
    defer e2.release();
    try std.testing.expectEqualStrings("y", e2.key.bytes);
    try std.testing.expectEqualStrings("overlay_y", e2.value.bytes);

    try std.testing.expect((try it.next()) == null);
}

test "ReadOnlyDb: iterator ordered deinit frees all resources (leak check)" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();
    try mem.put("a", "val_a_with_some_length");
    try mem.put("b", "val_b_with_some_length");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();
    const iface = ro.database();
    try iface.put("b", "overlay_b_with_some_length");
    try iface.put("c", "overlay_c_with_some_length");

    // Create and immediately deinit without consuming — must not leak
    {
        var it = try iface.iterator(true);
        it.deinit();
    }

    // Create, partially consume, then deinit — must not leak
    {
        var it2 = try iface.iterator(true);
        const e1 = try it2.next();
        if (e1) |e| e.release();
        it2.deinit();
    }
}

test "ReadOnlyDb: snapshot captures overlay and wrapped state" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("base", "old");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();
    try iface.put("overlay", "ov1");

    var snap = try iface.snapshot();
    defer snap.deinit();

    try mem.put("base", "new");
    try iface.put("overlay", "ov2");

    const base_val = (try snap.get("base", .none)).?;
    defer base_val.release();
    try std.testing.expectEqualStrings("old", base_val.bytes);

    const overlay_val = (try snap.get("overlay", .none)).?;
    defer overlay_val.release();
    try std.testing.expectEqualStrings("ov1", overlay_val.bytes);

    try std.testing.expect(try snap.contains("overlay"));
    try std.testing.expect(!try snap.contains("missing"));
    try std.testing.expectError(error.UnsupportedOperation, snap.iterator(false));
}

test "ReadOnlyDb: wrapped database never modified by overlay writes" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("existing", "original");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();

    // Overlay write to existing key
    try iface.put("existing", "modified");
    // Overlay write to new key
    try iface.put("new_key", "new_val");

    // Wrapped database should have NO changes
    const existing = mem.get("existing").?;
    defer existing.release();
    try std.testing.expectEqualStrings("original", existing.bytes);
    try std.testing.expect(mem.get("new_key") == null);

    // Even after clearing overlay, wrapped database is still pristine
    ro.clear_temp_changes();
    const existing_after = mem.get("existing").?;
    defer existing_after.release();
    try std.testing.expectEqualStrings("original", existing_after.bytes);
    try std.testing.expect(mem.get("new_key") == null);
}

test "ReadOnlyDb: deinit frees overlay memory (leak check)" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);

    // Write some data to the overlay
    const iface = ro.database();
    try iface.put("key1", "value1_with_some_length");
    try iface.put("key2", "value2_with_some_length");
    try iface.put("key3", "value3_with_some_length");

    // If deinit doesn't free properly, testing allocator will report a leak
    ro.deinit();
}

// -- multi_get tests ---------------------------------------------------------

test "ReadOnlyDb: multi_get delegates to wrapped (no overlay)" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("a", "val_a");
    try mem.put("b", "val_b");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    try std.testing.expect(iface.supports_multi_get());

    const keys = &[_][]const u8{ "a", "b", "c" };
    var results: [3]?adapter.DbValue = undefined;
    try iface.multi_get(keys, &results);

    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("val_a", results[0].?.bytes);
    try std.testing.expect(results[1] != null);
    try std.testing.expectEqualStrings("val_b", results[1].?.bytes);
    try std.testing.expect(results[2] == null);
}

test "ReadOnlyDb: multi_get overlay takes precedence over wrapped" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "wrapped_value");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();
    try iface.put("key", "overlay_value");

    const keys = &[_][]const u8{"key"};
    var results: [1]?adapter.DbValue = undefined;
    try iface.multi_get(keys, &results);

    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("overlay_value", results[0].?.bytes);

    // Wrapped database is untouched.
    const wrapped_val = mem.get("key").?;
    defer wrapped_val.release();
    try std.testing.expectEqualStrings("wrapped_value", wrapped_val.bytes);
}

test "ReadOnlyDb: multi_get with mix of overlay and wrapped keys" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("wrapped_only", "from_wrapped");
    try mem.put("both", "wrapped_both");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();
    try iface.put("overlay_only", "from_overlay");
    try iface.put("both", "overlay_both");

    const keys = &[_][]const u8{ "wrapped_only", "overlay_only", "both", "missing" };
    var results: [4]?adapter.DbValue = undefined;
    try iface.multi_get(keys, &results);

    // Key in wrapped only.
    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("from_wrapped", results[0].?.bytes);
    // Key in overlay only.
    try std.testing.expect(results[1] != null);
    try std.testing.expectEqualStrings("from_overlay", results[1].?.bytes);
    // Key in both — overlay wins.
    try std.testing.expect(results[2] != null);
    try std.testing.expectEqualStrings("overlay_both", results[2].?.bytes);
    // Key in neither.
    try std.testing.expect(results[3] == null);
}

test "ReadOnlyDb: multi_get after clear_temp_changes falls back to wrapped" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("key", "wrapped_value");

    var ro = try ReadOnlyDb.init_with_write_store(mem.database(), std.testing.allocator);
    defer ro.deinit();

    const iface = ro.database();
    try iface.put("key", "overlay_value");
    try iface.put("extra", "extra_val");

    // Clear overlay.
    ro.clear_temp_changes();

    const keys = &[_][]const u8{ "key", "extra" };
    var results: [2]?adapter.DbValue = undefined;
    try iface.multi_get(keys, &results);

    // Falls back to wrapped for "key".
    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("wrapped_value", results[0].?.bytes);
    // "extra" was overlay-only — now gone.
    try std.testing.expect(results[1] == null);
}

// -- Sorted view forwarding tests --------------------------------------------

test "ReadOnlyDb: supports_sorted_view forwards from wrapped" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    // MemoryDatabase supports sorted view, so ReadOnlyDb should too.
    try std.testing.expect(iface.supports_sorted_view());
}

test "ReadOnlyDb: first_key forwards to wrapped database" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("ccc", "3");
    try mem.put("aaa", "1");
    try mem.put("bbb", "2");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    const result = (try iface.first_key()).?;
    try std.testing.expectEqualStrings("aaa", result.bytes);
}

test "ReadOnlyDb: last_key forwards to wrapped database" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("aaa", "1");
    try mem.put("ccc", "3");
    try mem.put("bbb", "2");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    const result = (try iface.last_key()).?;
    try std.testing.expectEqualStrings("ccc", result.bytes);
}

test "ReadOnlyDb: get_view_between forwards to wrapped database" {
    var mem = MemoryDatabase.init(std.testing.allocator, .state);
    defer mem.deinit();

    try mem.put("aaa", "1");
    try mem.put("bbb", "2");
    try mem.put("ccc", "3");

    var ro = ReadOnlyDb.init(mem.database());
    defer ro.deinit();

    const iface = ro.database();
    var view = try iface.get_view_between("aaa", "ccc");
    defer view.deinit();

    const first = (try view.move_next()).?;
    try std.testing.expectEqualStrings("aaa", first.key.bytes);

    const second = (try view.move_next()).?;
    try std.testing.expectEqualStrings("bbb", second.key.bytes);

    try std.testing.expect((try view.move_next()) == null);
}
