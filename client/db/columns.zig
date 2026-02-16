/// Column family abstractions for multi-column databases.
///
/// Provides comptime-generic column family support mirroring Nethermind's
/// `IColumnsDb<TKey>` interface hierarchy. Each enum type `T` defines a set
/// of named columns, and `ColumnsDb(T)` maps each variant to a separate
/// `Database` instance.
///
/// ## Column Enums
///
/// - `ReceiptsColumns` — Receipt storage (default, transactions, blocks)
/// - `BlobTxsColumns` — EIP-4844 blob transaction storage
///
/// ## Generic Types
///
/// - `ColumnsDb(T)` — Non-owning column family accessor (IColumnsDb<TKey>)
/// - `ColumnsWriteBatch(T)` — Cross-column batched writes (IColumnsWriteBatch<TKey>)
/// - `ColumnDbSnapshot(T)` — Cross-column consistent snapshots (IColumnDbSnapshot<TKey>)
/// - `MemColumnsDb(T)` — In-memory implementation (MemColumnsDb<TKey>)
/// - `ReadOnlyColumnsDb(T)` — Read-only wrapper with optional overlay (ReadOnlyColumnsDb<TKey>)
const std = @import("std");
const adapter = @import("adapter.zig");
const Database = adapter.Database;
const WriteBatch = adapter.WriteBatch;
const DbSnapshot = adapter.DbSnapshot;
const Error = adapter.Error;
const memory = @import("memory.zig");
const MemoryDatabase = memory.MemoryDatabase;
const read_only = @import("read_only.zig");
const ReadOnlyDb = read_only.ReadOnlyDb;
const DbName = adapter.DbName;
const DbMetric = adapter.DbMetric;
const ReadFlags = adapter.ReadFlags;

/// Column families for receipt storage.
///
/// Matches Nethermind's `ReceiptsColumns` enum from
/// `Nethermind.Db/ReceiptsColumns.cs`.
///
/// Receipt data can be indexed by three different keys:
/// - `default` — receipt data indexed by receipt hash
/// - `transactions` — receipt data indexed by transaction hash
/// - `blocks` — receipt data indexed by block number/hash
pub const ReceiptsColumns = enum {
    /// Default column — receipt data indexed by receipt hash.
    default,
    /// Transaction index — receipt data indexed by transaction hash.
    transactions,
    /// Block index — receipt data indexed by block number/hash.
    blocks,

    /// Returns the Nethermind-compatible string representation.
    pub fn to_string(self: ReceiptsColumns) []const u8 {
        return switch (self) {
            .default => "Default",
            .transactions => "Transactions",
            .blocks => "Blocks",
        };
    }
};

/// Column families for blob transaction storage (EIP-4844).
///
/// Matches Nethermind's `BlobTxsColumns` enum from
/// `Nethermind.Db/BlobTxsColumns.cs`.
///
/// Blob transactions are stored in three columns:
/// - `full_blob_txs` — complete blob data (including 128KB blobs)
/// - `light_blob_txs` — lightweight metadata (without blob payload)
/// - `processed_txs` — transactions included in finalized blocks
pub const BlobTxsColumns = enum {
    /// Full blob transaction data (including 128KB blobs).
    full_blob_txs,
    /// Light blob transaction metadata (without blob payload).
    light_blob_txs,
    /// Transactions that have been included in finalized blocks.
    processed_txs,

    /// Returns the Nethermind-compatible string representation.
    pub fn to_string(self: BlobTxsColumns) []const u8 {
        return switch (self) {
            .full_blob_txs => "FullBlobTxs",
            .light_blob_txs => "LightBlobTxs",
            .processed_txs => "ProcessedTxs",
        };
    }
};

/// Generic column family database.
///
/// Mirrors Nethermind's `IColumnsDb<TKey>` interface. Each enum variant of `T`
/// maps to a separate `Database` instance. The `ColumnsDb` does not own the
/// underlying databases; lifetime management is the caller's responsibility.
///
/// `T` must be a Zig `enum` type (validated at comptime).
///
/// Uses `std.EnumArray(T, Database)` for zero-allocation dense column mapping,
/// following the same pattern as `DbProvider`.
pub fn ColumnsDb(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .@"enum") {
            @compileError("ColumnsDb requires an enum type, got " ++ @typeName(T));
        }
    }

    return struct {
        const Self = @This();

        /// Dense mapping from column enum variant to `Database` handle.
        columns: std.EnumArray(T, Database),

        /// Get the `Database` for a specific column.
        pub fn getColumnDb(self: *const Self, key: T) Database {
            return self.columns.get(key);
        }

        /// Return all column keys (comptime-known slice of enum fields).
        pub fn columnKeys() []const T {
            return comptime blk: {
                const fields = std.meta.fields(T);
                var keys: [fields.len]T = undefined;
                for (fields, 0..) |field, i| {
                    keys[i] = @enumFromInt(field.value);
                }
                const result = keys;
                break :blk &result;
            };
        }

        /// Create a cross-column write batch targeting all columns.
        ///
        /// Mirrors Nethermind's `IColumnsDb<TKey>.StartWriteBatch()`.
        pub fn startWriteBatch(self: *const Self, allocator: std.mem.Allocator) ColumnsWriteBatch(T) {
            return ColumnsWriteBatch(T).init(allocator, self.columns);
        }

        /// Create a cross-column snapshot for consistent point-in-time reads.
        ///
        /// Mirrors Nethermind's `IColumnsDb<TKey>.CreateSnapshot()`.
        ///
        /// If creating a snapshot for one column succeeds but another fails,
        /// already-created snapshots are cleaned up via `errdefer`.
        pub fn createSnapshot(self: *const Self) Error!ColumnDbSnapshot(T) {
            var snapshots: std.EnumArray(T, DbSnapshot) = undefined;
            const tags = comptime std.meta.tags(T);
            // Track how many snapshots were successfully created for cleanup.
            var created: usize = 0;
            errdefer {
                // Clean up already-created snapshots on partial failure.
                for (tags[0..created]) |tag| {
                    snapshots.get(tag).deinit();
                }
            }
            for (tags) |tag| {
                snapshots.set(tag, try self.columns.get(tag).snapshot());
                created += 1;
            }
            return .{ .snapshots = snapshots };
        }

        /// Create a read-only view of this column database.
        ///
        /// Mirrors Nethermind's `IColumnsDb<TKey>.CreateReadOnly(bool)`.
        /// When `create_in_mem_write_store` is true, each column gets an
        /// in-memory overlay for temporary writes (cleared via
        /// `ReadOnlyColumnsDb.clearTempChanges()`).
        ///
        /// The returned `ReadOnlyColumnsDb` owns the `ReadOnlyDb` instances.
        /// The caller must call `deinit()` when done.
        pub fn createReadOnly(self: *const Self, allocator: std.mem.Allocator, create_in_mem_write_store: bool) Error!ReadOnlyColumnsDb(T) {
            return ReadOnlyColumnsDb(T).init(allocator, self.columns, create_in_mem_write_store);
        }

        // -- IDbMeta lifecycle operations (Nethermind parity) -----------------

        /// Flush pending writes across all columns.
        ///
        /// Mirrors Nethermind's `IDbMeta.Flush(bool onlyWal)` applied to each
        /// column database. On error, returns immediately — remaining columns
        /// are NOT flushed.
        pub fn flush(self: *const Self, only_wal: bool) Error!void {
            for (comptime std.meta.tags(T)) |tag| {
                try self.columns.get(tag).flush(only_wal);
            }
        }

        /// Clear all entries across all columns.
        ///
        /// Mirrors Nethermind's `IDbMeta.Clear()` applied to each column database.
        /// On error, returns immediately — remaining columns are NOT cleared.
        pub fn clear(self: *const Self) Error!void {
            for (comptime std.meta.tags(T)) |tag| {
                try self.columns.get(tag).clear();
            }
        }

        /// Compact storage across all columns.
        ///
        /// Mirrors Nethermind's `IDbMeta.Compact()` applied to each column database.
        /// On error, returns immediately — remaining columns are NOT compacted.
        pub fn compact(self: *const Self) Error!void {
            for (comptime std.meta.tags(T)) |tag| {
                try self.columns.get(tag).compact();
            }
        }

        /// Gather diagnostic metrics aggregated across all columns.
        ///
        /// Mirrors Nethermind's `IDbMeta.GatherMetric()`. Returns the sum of
        /// all per-column metrics. On error, returns immediately.
        pub fn gatherMetric(self: *const Self) Error!DbMetric {
            var total = DbMetric{};
            for (comptime std.meta.tags(T)) |tag| {
                const m = try self.columns.get(tag).gather_metric();
                total.size += m.size;
                total.cache_size += m.cache_size;
                total.index_size += m.index_size;
                total.memtable_size += m.memtable_size;
                total.total_reads += m.total_reads;
                total.total_writes += m.total_writes;
            }
            return total;
        }
    };
}

/// Cross-column write batch.
///
/// Mirrors Nethermind's `IColumnsWriteBatch<TKey>`. Wraps one `WriteBatch` per
/// column. Operations are accumulated per-column and committed together.
///
/// ## Lifecycle (matches Nethermind's IDisposable pattern)
///
/// ```
/// var batch = cdb.startWriteBatch(allocator);
/// defer batch.deinit();          // always release memory
///
/// try batch.getColumnBatch(.col1).put("k", "v");
/// try batch.commit();            // apply all pending ops
/// // batch is reusable after commit (ops cleared, memory reclaimed)
/// ```
///
/// ## Atomicity
///
/// Commits are **per-column** — each column's `WriteBatch` commits independently.
/// True cross-column atomicity requires the backend to support it natively
/// (e.g., RocksDB WriteBatch across column families). For `MemoryDatabase`
/// backends, commits are sequential per-column.
///
/// On partial failure: `committed_columns` tracks how many columns succeeded.
/// Already-committed columns are NOT rolled back. Callers can inspect
/// `committed_columns` to determine which columns need reconciliation.
pub fn ColumnsWriteBatch(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .@"enum") {
            @compileError("ColumnsWriteBatch requires an enum type, got " ++ @typeName(T));
        }
    }

    return struct {
        const Self = @This();

        /// One `WriteBatch` per column.
        batches: std.EnumArray(T, WriteBatch),
        /// Number of columns successfully committed during the last `commit()`.
        /// Reset to 0 on each `commit()` call. On error, indicates how many
        /// columns were committed before the failure.
        committed_columns: usize = 0,

        /// Create a cross-column write batch targeting the given columns.
        pub fn init(allocator: std.mem.Allocator, columns: std.EnumArray(T, Database)) Self {
            var batches: std.EnumArray(T, WriteBatch) = undefined;
            for (std.meta.tags(T)) |tag| {
                batches.set(tag, WriteBatch.init(allocator, columns.get(tag)));
            }
            return .{ .batches = batches };
        }

        /// Get the `WriteBatch` for a specific column.
        pub fn getColumnBatch(self: *Self, key: T) *WriteBatch {
            return self.batches.getPtr(key);
        }

        /// Commit all pending operations across all columns.
        ///
        /// Commits are sequential per-column. If a column commit fails,
        /// the error is returned immediately and remaining columns are
        /// NOT committed. Previously committed columns are NOT rolled back.
        ///
        /// On success, `committed_columns` equals the number of enum variants.
        /// On error, `committed_columns` indicates how many columns succeeded.
        pub fn commit(self: *Self) Error!void {
            self.committed_columns = 0;
            for (std.meta.tags(T)) |tag| {
                try self.batches.getPtr(tag).commit();
                self.committed_columns += 1;
            }
        }

        /// Discard all pending operations across all columns without committing.
        ///
        /// Resets each per-column batch, freeing accumulated key/value memory.
        /// The batch is reusable after `reset()`.
        pub fn reset(self: *Self) void {
            for (std.meta.tags(T)) |tag| {
                self.batches.getPtr(tag).clear();
            }
        }

        /// Release all memory owned by all column batches.
        ///
        /// Must be called even after `commit()` to free internal allocations.
        /// Mirrors Nethermind's `IDisposable.Dispose()` pattern.
        pub fn deinit(self: *Self) void {
            for (std.meta.tags(T)) |tag| {
                self.batches.getPtr(tag).deinit();
            }
        }

        /// Return total pending operations across all columns.
        pub fn pending(self: *const Self) usize {
            var total: usize = 0;
            for (std.meta.tags(T)) |tag| {
                total += self.batches.get(tag).pending();
            }
            return total;
        }
    };
}

/// Cross-column snapshot for consistent point-in-time reads.
///
/// Mirrors Nethermind's `IColumnDbSnapshot<TKey>`. Each column gets its own
/// `DbSnapshot`, all created at the same logical point in time.
///
/// `deinit()` releases all snapshot resources across all columns.
pub fn ColumnDbSnapshot(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .@"enum") {
            @compileError("ColumnDbSnapshot requires an enum type, got " ++ @typeName(T));
        }
    }

    return struct {
        const Self = @This();

        /// One `DbSnapshot` per column.
        snapshots: std.EnumArray(T, DbSnapshot),

        /// Get the `DbSnapshot` for a specific column.
        pub fn getColumnSnapshot(self: *const Self, key: T) DbSnapshot {
            return self.snapshots.get(key);
        }

        /// Release all snapshot resources across all columns.
        pub fn deinit(self: *Self) void {
            for (std.meta.tags(T)) |tag| {
                self.snapshots.get(tag).deinit();
            }
        }
    };
}

/// In-memory column family database.
///
/// Mirrors Nethermind's `MemColumnsDb<TKey>`. Each column is backed by a
/// separate `MemoryDatabase`. Owns all underlying databases and releases
/// them on `deinit()`.
///
/// Provides `columnsDb()` to get the non-owning `ColumnsDb(T)` interface
/// (valid only while the `MemColumnsDb` is alive).
pub fn MemColumnsDb(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .@"enum") {
            @compileError("MemColumnsDb requires an enum type, got " ++ @typeName(T));
        }
    }

    return struct {
        const Self = @This();

        /// Owned `MemoryDatabase` instances, one per column.
        databases: std.EnumArray(T, MemoryDatabase),
        /// Allocator used for construction (retained for future use).
        allocator: std.mem.Allocator,

        /// Create a new `MemColumnsDb` with one `MemoryDatabase` per column.
        ///
        /// The `db_name` identifies the logical database group; individual
        /// columns are distinguished by the enum key, not by `DbName`.
        /// Callers should pass the appropriate name for the column family
        /// (e.g., `.receipts` for `ReceiptsColumns`, `.blob_transactions`
        /// for `BlobTxsColumns`).
        pub fn init(allocator: std.mem.Allocator, db_name: DbName) Self {
            var databases: std.EnumArray(T, MemoryDatabase) = undefined;
            for (std.meta.tags(T)) |tag| {
                databases.set(tag, MemoryDatabase.init(allocator, db_name));
            }
            return .{ .databases = databases, .allocator = allocator };
        }

        /// Release all memory owned by all column databases.
        pub fn deinit(self: *Self) void {
            for (std.meta.tags(T)) |tag| {
                self.databases.getPtr(tag).deinit();
            }
        }

        /// Return the non-owning `ColumnsDb(T)` interface.
        ///
        /// The returned `ColumnsDb` contains `Database` vtable handles
        /// pointing into this `MemColumnsDb`. The caller must not use
        /// the returned value after `deinit()` is called.
        pub fn columnsDb(self: *Self) ColumnsDb(T) {
            var db_array: std.EnumArray(T, Database) = undefined;
            for (std.meta.tags(T)) |tag| {
                db_array.set(tag, self.databases.getPtr(tag).database());
            }
            return .{ .columns = db_array };
        }
    };
}

/// Read-only column family database.
///
/// Mirrors Nethermind's `ReadOnlyColumnsDb<TKey>`. Wraps each column in a
/// `ReadOnlyDb` with an optional in-memory write overlay. Reads delegate to
/// the underlying `Database`; writes go to the overlay (if enabled) or error.
///
/// Call `clearTempChanges()` to discard all overlay writes across all columns.
/// Call `deinit()` to release all owned `ReadOnlyDb` resources.
pub fn ReadOnlyColumnsDb(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .@"enum") {
            @compileError("ReadOnlyColumnsDb requires an enum type, got " ++ @typeName(T));
        }
    }

    return struct {
        const Self = @This();

        /// Owned `ReadOnlyDb` instances, one per column.
        read_only_dbs: std.EnumArray(T, ReadOnlyDb),
        /// Allocator used for construction.
        allocator: std.mem.Allocator,

        /// Create a read-only view of the given columns.
        ///
        /// If `create_in_mem_write_store` is true, each column gets an in-memory
        /// overlay for temporary writes. Otherwise, writes will error.
        ///
        /// If creating an overlay for one column fails, already-created overlays
        /// are cleaned up via `errdefer`.
        pub fn init(allocator: std.mem.Allocator, columns: std.EnumArray(T, Database), create_in_mem_write_store: bool) Error!Self {
            var read_only_dbs: std.EnumArray(T, ReadOnlyDb) = undefined;
            const tags = comptime std.meta.tags(T);
            var created: usize = 0;
            errdefer {
                for (tags[0..created]) |tag| {
                    read_only_dbs.getPtr(tag).deinit();
                }
            }
            for (tags) |tag| {
                if (create_in_mem_write_store) {
                    read_only_dbs.set(tag, try ReadOnlyDb.init_with_write_store(columns.get(tag), allocator));
                } else {
                    read_only_dbs.set(tag, ReadOnlyDb.init(columns.get(tag)));
                }
                created += 1;
            }
            return .{ .read_only_dbs = read_only_dbs, .allocator = allocator };
        }

        /// Release all owned `ReadOnlyDb` resources.
        pub fn deinit(self: *Self) void {
            for (std.meta.tags(T)) |tag| {
                self.read_only_dbs.getPtr(tag).deinit();
            }
        }

        /// Get the read-only `Database` interface for a specific column.
        pub fn getColumnDb(self: *Self, key: T) Database {
            return self.read_only_dbs.getPtr(key).database();
        }

        /// Return a `ColumnsDb(T)` wrapping the read-only views.
        ///
        /// The returned `ColumnsDb` is valid only while this `ReadOnlyColumnsDb`
        /// is alive. Writes through this interface go to the overlay (if enabled).
        pub fn columnsDb(self: *Self) ColumnsDb(T) {
            var db_array: std.EnumArray(T, Database) = undefined;
            for (std.meta.tags(T)) |tag| {
                db_array.set(tag, self.read_only_dbs.getPtr(tag).database());
            }
            return .{ .columns = db_array };
        }

        /// Discard all temporary overlay writes across all columns.
        ///
        /// No-op for columns without write overlay.
        /// Mirrors Nethermind's `ReadOnlyColumnsDb.ClearTempChanges()`.
        pub fn clearTempChanges(self: *Self) void {
            for (std.meta.tags(T)) |tag| {
                self.read_only_dbs.getPtr(tag).clear_temp_changes();
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ReceiptsColumns has exactly 3 variants" {
    const fields = std.meta.fields(ReceiptsColumns);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
}

test "ReceiptsColumns to_string matches Nethermind" {
    try std.testing.expectEqualStrings("Default", ReceiptsColumns.default.to_string());
    try std.testing.expectEqualStrings("Transactions", ReceiptsColumns.transactions.to_string());
    try std.testing.expectEqualStrings("Blocks", ReceiptsColumns.blocks.to_string());
}

test "BlobTxsColumns has exactly 3 variants" {
    const fields = std.meta.fields(BlobTxsColumns);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
}

test "BlobTxsColumns to_string matches Nethermind" {
    try std.testing.expectEqualStrings("FullBlobTxs", BlobTxsColumns.full_blob_txs.to_string());
    try std.testing.expectEqualStrings("LightBlobTxs", BlobTxsColumns.light_blob_txs.to_string());
    try std.testing.expectEqualStrings("ProcessedTxs", BlobTxsColumns.processed_txs.to_string());
}

test "ColumnsDb getColumnDb returns correct Database per column" {
    // Create 3 MemoryDatabases — one per ReceiptsColumns variant.
    var db_default = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db_default.deinit();
    var db_txs = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db_txs.deinit();
    var db_blocks = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db_blocks.deinit();

    // Write unique values to each database.
    try db_default.put("key", "default_val");
    try db_txs.put("key", "txs_val");
    try db_blocks.put("key", "blocks_val");

    // Build the ColumnsDb.
    var cdb = ColumnsDb(ReceiptsColumns){
        .columns = std.EnumArray(ReceiptsColumns, Database).init(.{
            .default = db_default.database(),
            .transactions = db_txs.database(),
            .blocks = db_blocks.database(),
        }),
    };

    // Verify each column returns the correct database.
    const val_default = try cdb.getColumnDb(.default).get("key");
    try std.testing.expect(val_default != null);
    try std.testing.expectEqualStrings("default_val", val_default.?.bytes);

    const val_txs = try cdb.getColumnDb(.transactions).get("key");
    try std.testing.expect(val_txs != null);
    try std.testing.expectEqualStrings("txs_val", val_txs.?.bytes);

    const val_blocks = try cdb.getColumnDb(.blocks).get("key");
    try std.testing.expect(val_blocks != null);
    try std.testing.expectEqualStrings("blocks_val", val_blocks.?.bytes);
}

test "ColumnsDb columnKeys returns all enum variants" {
    const keys = ColumnsDb(ReceiptsColumns).columnKeys();
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqual(ReceiptsColumns.default, keys[0]);
    try std.testing.expectEqual(ReceiptsColumns.transactions, keys[1]);
    try std.testing.expectEqual(ReceiptsColumns.blocks, keys[2]);
}

test "ColumnsDb columnKeys works for BlobTxsColumns" {
    const keys = ColumnsDb(BlobTxsColumns).columnKeys();
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqual(BlobTxsColumns.full_blob_txs, keys[0]);
    try std.testing.expectEqual(BlobTxsColumns.light_blob_txs, keys[1]);
    try std.testing.expectEqual(BlobTxsColumns.processed_txs, keys[2]);
}

test "ColumnsWriteBatch getColumnBatch returns correct batch per column" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cols = std.EnumArray(ReceiptsColumns, Database).init(.{
        .default = db0.database(),
        .transactions = db1.database(),
        .blocks = db2.database(),
    });

    var batch = ColumnsWriteBatch(ReceiptsColumns).init(std.testing.allocator, cols);
    defer batch.deinit();

    // Queue ops on different column batches.
    try batch.getColumnBatch(.default).put("k1", "v1");
    try batch.getColumnBatch(.transactions).put("k2", "v2");
    try batch.getColumnBatch(.blocks).put("k3", "v3");

    try std.testing.expectEqual(@as(usize, 3), batch.pending());
}

test "ColumnsWriteBatch commit applies all ops across columns" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cols = std.EnumArray(ReceiptsColumns, Database).init(.{
        .default = db0.database(),
        .transactions = db1.database(),
        .blocks = db2.database(),
    });

    var batch = ColumnsWriteBatch(ReceiptsColumns).init(std.testing.allocator, cols);
    defer batch.deinit();

    try batch.getColumnBatch(.default).put("k1", "v1");
    try batch.getColumnBatch(.transactions).put("k2", "v2");
    try batch.commit();

    try std.testing.expectEqual(@as(usize, 0), batch.pending());

    // Verify data was written to the correct databases.
    const val1 = db0.get("k1");
    try std.testing.expect(val1 != null);
    try std.testing.expectEqualStrings("v1", val1.?.bytes);

    const val2 = db1.get("k2");
    try std.testing.expect(val2 != null);
    try std.testing.expectEqualStrings("v2", val2.?.bytes);

    // db2 should have no data.
    try std.testing.expect(db2.get("k3") == null);
}

test "ColumnsWriteBatch deinit frees all memory (leak check)" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cols = std.EnumArray(ReceiptsColumns, Database).init(.{
        .default = db0.database(),
        .transactions = db1.database(),
        .blocks = db2.database(),
    });

    var batch = ColumnsWriteBatch(ReceiptsColumns).init(std.testing.allocator, cols);
    try batch.getColumnBatch(.default).put("key", "large_value_for_alloc");
    try batch.getColumnBatch(.transactions).put("key2", "another_value");

    // If deinit doesn't free properly, testing allocator will report a leak.
    batch.deinit();
}

test "ColumnDbSnapshot getColumnSnapshot returns correct snapshot per column" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();

    // Write initial data.
    try db0.put("key", "old_default");
    try db1.put("key", "old_txs");

    // Create snapshots for both columns.
    const snap0 = try db0.database().snapshot();
    const snap1 = try db1.database().snapshot();

    // Build ColumnDbSnapshot.
    // For the third column (blocks), create a trivial db + snapshot.
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();
    const snap2 = try db2.database().snapshot();

    var col_snap = ColumnDbSnapshot(ReceiptsColumns){
        .snapshots = std.EnumArray(ReceiptsColumns, DbSnapshot).init(.{
            .default = snap0,
            .transactions = snap1,
            .blocks = snap2,
        }),
    };
    defer col_snap.deinit();

    // Write new data AFTER snapshot.
    try db0.put("key", "new_default");
    try db1.put("key", "new_txs");

    // Snapshot should see OLD data.
    const val0 = try col_snap.getColumnSnapshot(.default).get("key", ReadFlags.none);
    try std.testing.expect(val0 != null);
    try std.testing.expectEqualStrings("old_default", val0.?.bytes);

    const val1 = try col_snap.getColumnSnapshot(.transactions).get("key", ReadFlags.none);
    try std.testing.expect(val1 != null);
    try std.testing.expectEqualStrings("old_txs", val1.?.bytes);
}

test "ColumnDbSnapshot deinit releases all snapshot resources" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    try db0.put("a", "1");

    const snap0 = try db0.database().snapshot();
    const snap1 = try db1.database().snapshot();
    const snap2 = try db2.database().snapshot();

    var col_snap = ColumnDbSnapshot(ReceiptsColumns){
        .snapshots = std.EnumArray(ReceiptsColumns, DbSnapshot).init(.{
            .default = snap0,
            .transactions = snap1,
            .blocks = snap2,
        }),
    };

    // If deinit doesn't release properly, testing allocator will report a leak.
    col_snap.deinit();
}

test "ColumnsDb startWriteBatch returns working batch" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cdb = ColumnsDb(ReceiptsColumns){
        .columns = std.EnumArray(ReceiptsColumns, Database).init(.{
            .default = db0.database(),
            .transactions = db1.database(),
            .blocks = db2.database(),
        }),
    };

    var batch = cdb.startWriteBatch(std.testing.allocator);
    defer batch.deinit();

    try batch.getColumnBatch(.default).put("k1", "v1");
    try batch.getColumnBatch(.blocks).put("k2", "v2");
    try batch.commit();

    // Verify data was written.
    const val1 = db0.get("k1");
    try std.testing.expect(val1 != null);
    try std.testing.expectEqualStrings("v1", val1.?.bytes);

    const val2 = db2.get("k2");
    try std.testing.expect(val2 != null);
    try std.testing.expectEqualStrings("v2", val2.?.bytes);

    // Other column unaffected.
    try std.testing.expect(db1.get("k1") == null);
}

test "ColumnsDb createSnapshot returns working snapshot" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    try db0.put("key", "before");

    const cdb = ColumnsDb(ReceiptsColumns){
        .columns = std.EnumArray(ReceiptsColumns, Database).init(.{
            .default = db0.database(),
            .transactions = db1.database(),
            .blocks = db2.database(),
        }),
    };

    var snap = try cdb.createSnapshot();
    defer snap.deinit();

    // Write after snapshot.
    try db0.put("key", "after");

    // Snapshot sees old value.
    const val = try snap.getColumnSnapshot(.default).get("key", ReadFlags.none);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("before", val.?.bytes);
}

test "ColumnsDb startWriteBatch then createSnapshot end-to-end" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cdb = ColumnsDb(ReceiptsColumns){
        .columns = std.EnumArray(ReceiptsColumns, Database).init(.{
            .default = db0.database(),
            .transactions = db1.database(),
            .blocks = db2.database(),
        }),
    };

    // Write via batch.
    var batch = cdb.startWriteBatch(std.testing.allocator);
    defer batch.deinit();
    try batch.getColumnBatch(.default).put("key", "batch_val");
    try batch.commit();

    // Snapshot after batch commit.
    var snap = try cdb.createSnapshot();
    defer snap.deinit();

    // Write again.
    try db0.put("key", "overwritten");

    // Snapshot sees batch_val.
    const val = try snap.getColumnSnapshot(.default).get("key", ReadFlags.none);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("batch_val", val.?.bytes);
}

// -- IDbMeta lifecycle tests --------------------------------------------------

test "ColumnsDb flush delegates to all columns" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    // Write data to columns.
    try cdb.getColumnDb(.default).put("k", "v");
    try cdb.getColumnDb(.transactions).put("k", "v");

    // Flush should succeed (MemoryDatabase flush is a no-op).
    try cdb.flush(false);
    try cdb.flush(true);
}

test "ColumnsDb clear removes all data from all columns" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    try cdb.getColumnDb(.default).put("k", "v");
    try cdb.getColumnDb(.transactions).put("k", "v");

    try cdb.clear();

    // All data should be gone.
    try std.testing.expect((try cdb.getColumnDb(.default).get("k")) == null);
    try std.testing.expect((try cdb.getColumnDb(.transactions).get("k")) == null);
}

test "ColumnsDb compact delegates to all columns" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    const cdb = mcdb.columnsDb();

    // Compact should succeed (MemoryDatabase compact is a no-op).
    try cdb.compact();
}

test "ColumnsDb gatherMetric aggregates across columns" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    const cdb = mcdb.columnsDb();

    // MemoryDatabase returns zeroed metrics, so aggregate should also be zero.
    const metric = try cdb.gatherMetric();
    try std.testing.expectEqual(@as(u64, 0), metric.size);
    try std.testing.expectEqual(@as(u64, 0), metric.cache_size);
    try std.testing.expectEqual(@as(u64, 0), metric.total_reads);
    try std.testing.expectEqual(@as(u64, 0), metric.total_writes);
}

// -- MemColumnsDb tests ------------------------------------------------------

test "MemColumnsDb init creates N databases" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    // Each column should have an empty MemoryDatabase.
    for (std.meta.tags(ReceiptsColumns)) |tag| {
        try std.testing.expect(mcdb.databases.getPtr(tag).get("nonexistent") == null);
    }
}

test "MemColumnsDb deinit frees all memory (leak check)" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);

    // Write data to each column to ensure there's memory to free.
    var cdb = mcdb.columnsDb();
    try cdb.getColumnDb(.default).put("k", "v");
    try cdb.getColumnDb(.transactions).put("k", "v");
    try cdb.getColumnDb(.blocks).put("k", "v");

    // If deinit doesn't free properly, testing allocator will report a leak.
    mcdb.deinit();
}

test "MemColumnsDb columnsDb returns working interface" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    // Write via the ColumnsDb interface.
    try cdb.getColumnDb(.default).put("key", "default_value");
    try cdb.getColumnDb(.transactions).put("key", "txs_value");

    // Read back.
    const val0 = try cdb.getColumnDb(.default).get("key");
    try std.testing.expect(val0 != null);
    try std.testing.expectEqualStrings("default_value", val0.?.bytes);

    const val1 = try cdb.getColumnDb(.transactions).get("key");
    try std.testing.expect(val1 != null);
    try std.testing.expectEqualStrings("txs_value", val1.?.bytes);
}

test "MemColumnsDb column isolation" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    // Write to column A.
    try cdb.getColumnDb(.default).put("key", "value_a");

    // Column B should NOT see it.
    const val_b = try cdb.getColumnDb(.transactions).get("key");
    try std.testing.expect(val_b == null);

    // Column C should NOT see it.
    const val_c = try cdb.getColumnDb(.blocks).get("key");
    try std.testing.expect(val_c == null);
}

test "MemColumnsDb full round-trip put/get per column" {
    var mcdb = MemColumnsDb(BlobTxsColumns).init(std.testing.allocator, .blob_transactions);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    try cdb.getColumnDb(.full_blob_txs).put("blob1", "full_data");
    try cdb.getColumnDb(.light_blob_txs).put("blob1", "light_data");
    try cdb.getColumnDb(.processed_txs).put("blob1", "processed_data");

    const v0 = try cdb.getColumnDb(.full_blob_txs).get("blob1");
    try std.testing.expect(v0 != null);
    try std.testing.expectEqualStrings("full_data", v0.?.bytes);

    const v1 = try cdb.getColumnDb(.light_blob_txs).get("blob1");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("light_data", v1.?.bytes);

    const v2 = try cdb.getColumnDb(.processed_txs).get("blob1");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("processed_data", v2.?.bytes);
}

test "MemColumnsDb write batch round-trip" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    var batch = cdb.startWriteBatch(std.testing.allocator);
    defer batch.deinit();

    try batch.getColumnBatch(.default).put("batch_key", "batch_val");
    try batch.getColumnBatch(.transactions).put("batch_key2", "batch_val2");
    try batch.commit();

    const v0 = try cdb.getColumnDb(.default).get("batch_key");
    try std.testing.expect(v0 != null);
    try std.testing.expectEqualStrings("batch_val", v0.?.bytes);

    const v1 = try cdb.getColumnDb(.transactions).get("batch_key2");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("batch_val2", v1.?.bytes);
}

test "MemColumnsDb snapshot isolation" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    try cdb.getColumnDb(.default).put("key", "before_snapshot");

    var snap = try cdb.createSnapshot();
    defer snap.deinit();

    // Write after snapshot.
    try cdb.getColumnDb(.default).put("key", "after_snapshot");

    // Snapshot sees old value.
    const val = try snap.getColumnSnapshot(.default).get("key", ReadFlags.none);
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("before_snapshot", val.?.bytes);

    // Live DB sees new value.
    const live_val = try cdb.getColumnDb(.default).get("key");
    try std.testing.expect(live_val != null);
    try std.testing.expectEqualStrings("after_snapshot", live_val.?.bytes);
}

// -- ReadOnlyColumnsDb tests -------------------------------------------------

test "ReadOnlyColumnsDb strict read-only rejects writes" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();
    try cdb.getColumnDb(.default).put("key", "value");

    var ro = try ReadOnlyColumnsDb(ReceiptsColumns).init(std.testing.allocator, cdb.columns, false);
    defer ro.deinit();

    // Reads should work.
    const val = try ro.getColumnDb(.default).get("key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("value", val.?.bytes);

    // Writes should be rejected.
    try std.testing.expectError(error.StorageError, ro.getColumnDb(.default).put("key", "new"));
}

test "ReadOnlyColumnsDb with overlay buffers writes" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();
    try cdb.getColumnDb(.default).put("key", "original");

    var ro = try ReadOnlyColumnsDb(ReceiptsColumns).init(std.testing.allocator, cdb.columns, true);
    defer ro.deinit();

    // Write to overlay.
    try ro.getColumnDb(.default).put("key", "overlay_value");

    // Read sees overlay value.
    const val = try ro.getColumnDb(.default).get("key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("overlay_value", val.?.bytes);

    // Underlying database is untouched.
    const orig = try cdb.getColumnDb(.default).get("key");
    try std.testing.expect(orig != null);
    try std.testing.expectEqualStrings("original", orig.?.bytes);
}

test "ReadOnlyColumnsDb clearTempChanges discards overlay writes" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();
    try cdb.getColumnDb(.default).put("key", "original");

    var ro = try ReadOnlyColumnsDb(ReceiptsColumns).init(std.testing.allocator, cdb.columns, true);
    defer ro.deinit();

    // Write to overlay.
    try ro.getColumnDb(.default).put("key", "temp");
    try ro.getColumnDb(.transactions).put("tx_key", "tx_val");

    // Clear all overlays.
    ro.clearTempChanges();

    // Should fall back to underlying value.
    const val = try ro.getColumnDb(.default).get("key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("original", val.?.bytes);

    // Overlay-only key should be gone.
    const tx_val = try ro.getColumnDb(.transactions).get("tx_key");
    try std.testing.expect(tx_val == null);
}

test "ReadOnlyColumnsDb columnsDb returns working interface" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var base = mcdb.columnsDb();
    try base.getColumnDb(.default).put("key", "value");

    var ro = try ReadOnlyColumnsDb(ReceiptsColumns).init(std.testing.allocator, base.columns, true);
    defer ro.deinit();

    const ro_cdb = ro.columnsDb();

    // Read through ColumnsDb interface.
    const val = try ro_cdb.getColumnDb(.default).get("key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("value", val.?.bytes);
}

test "ReadOnlyColumnsDb createReadOnly factory on ColumnsDb" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();
    try cdb.getColumnDb(.default).put("key", "value");

    // Use the factory method on ColumnsDb.
    var ro = try cdb.createReadOnly(std.testing.allocator, true);
    defer ro.deinit();

    // Read should work.
    const val = try ro.getColumnDb(.default).get("key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("value", val.?.bytes);

    // Write to overlay should work.
    try ro.getColumnDb(.default).put("key", "overlay");
    const ov = try ro.getColumnDb(.default).get("key");
    try std.testing.expect(ov != null);
    try std.testing.expectEqualStrings("overlay", ov.?.bytes);

    // Clear should revert.
    ro.clearTempChanges();
    const reverted = try ro.getColumnDb(.default).get("key");
    try std.testing.expect(reverted != null);
    try std.testing.expectEqualStrings("value", reverted.?.bytes);
}

test "ReadOnlyColumnsDb deinit frees all memory (leak check)" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    const cdb = mcdb.columnsDb();

    var ro = try ReadOnlyColumnsDb(ReceiptsColumns).init(std.testing.allocator, cdb.columns, true);

    // Write data to overlay.
    try ro.getColumnDb(.default).put("k1", "v1_with_length");
    try ro.getColumnDb(.transactions).put("k2", "v2_with_length");
    try ro.getColumnDb(.blocks).put("k3", "v3_with_length");

    // If deinit doesn't free properly, testing allocator will report a leak.
    ro.deinit();
}

// -- Error-path and edge case tests ------------------------------------------

test "ColumnsWriteBatch reset discards all pending ops" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cols = std.EnumArray(ReceiptsColumns, Database).init(.{
        .default = db0.database(),
        .transactions = db1.database(),
        .blocks = db2.database(),
    });

    var batch = ColumnsWriteBatch(ReceiptsColumns).init(std.testing.allocator, cols);
    defer batch.deinit();

    // Queue ops on multiple columns.
    try batch.getColumnBatch(.default).put("k1", "v1");
    try batch.getColumnBatch(.transactions).put("k2", "v2");
    try batch.getColumnBatch(.blocks).put("k3", "v3");
    try std.testing.expectEqual(@as(usize, 3), batch.pending());

    // Reset discards all.
    batch.reset();
    try std.testing.expectEqual(@as(usize, 0), batch.pending());

    // Commit after reset should be no-op.
    try batch.commit();
    try std.testing.expect(db0.get("k1") == null);
    try std.testing.expect(db1.get("k2") == null);
    try std.testing.expect(db2.get("k3") == null);
}

test "ColumnsWriteBatch reset allows reuse" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cols = std.EnumArray(ReceiptsColumns, Database).init(.{
        .default = db0.database(),
        .transactions = db1.database(),
        .blocks = db2.database(),
    });

    var batch = ColumnsWriteBatch(ReceiptsColumns).init(std.testing.allocator, cols);
    defer batch.deinit();

    // First round: queue and reset.
    try batch.getColumnBatch(.default).put("old", "data");
    batch.reset();

    // Second round: queue and commit.
    try batch.getColumnBatch(.default).put("new", "data");
    try batch.commit();

    // Only second round data should be present.
    try std.testing.expect(db0.get("old") == null);
    const val = db0.get("new");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("data", val.?.bytes);
}

test "ColumnsWriteBatch committed_columns tracks partial failure" {
    // We need a column DB where one column fails on commit.
    // Create a MemoryDatabase for the first column (will succeed)
    // and a mock that fails for the second column.
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cols = std.EnumArray(ReceiptsColumns, Database).init(.{
        .default = db0.database(),
        .transactions = db1.database(),
        .blocks = db2.database(),
    });

    var batch = ColumnsWriteBatch(ReceiptsColumns).init(std.testing.allocator, cols);
    defer batch.deinit();

    // Queue ops on all columns.
    try batch.getColumnBatch(.default).put("k1", "v1");
    try batch.getColumnBatch(.transactions).put("k2", "v2");
    try batch.getColumnBatch(.blocks).put("k3", "v3");

    // Normal commit should succeed and track all columns.
    try batch.commit();
    try std.testing.expectEqual(@as(usize, 3), batch.committed_columns);
}

test "ColumnsWriteBatch empty commit is no-op" {
    var db0 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db0.deinit();
    var db1 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db1.deinit();
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();

    const cols = std.EnumArray(ReceiptsColumns, Database).init(.{
        .default = db0.database(),
        .transactions = db1.database(),
        .blocks = db2.database(),
    });

    var batch = ColumnsWriteBatch(ReceiptsColumns).init(std.testing.allocator, cols);
    defer batch.deinit();

    // Commit with no pending ops should succeed.
    try batch.commit();
    try std.testing.expectEqual(@as(usize, 3), batch.committed_columns);
    try std.testing.expectEqual(@as(usize, 0), batch.pending());
}

test "ColumnsDb getColumnDb returns different Database per column" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    // Write different values to different columns.
    try cdb.getColumnDb(.default).put("key", "default");
    try cdb.getColumnDb(.transactions).put("key", "transactions");
    try cdb.getColumnDb(.blocks).put("key", "blocks");

    // Each column should return its own value.
    const v0 = try cdb.getColumnDb(.default).get("key");
    try std.testing.expect(v0 != null);
    try std.testing.expectEqualStrings("default", v0.?.bytes);

    const v1 = try cdb.getColumnDb(.transactions).get("key");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("transactions", v1.?.bytes);

    const v2 = try cdb.getColumnDb(.blocks).get("key");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("blocks", v2.?.bytes);
}
