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
/// - `ColumnsDb(T)` — Non-owning column family accessor
/// - `ColumnsWriteBatch(T)` — Cross-column batched writes
/// - `ColumnDbSnapshot(T)` — Cross-column consistent snapshots
/// - `MemColumnsDb(T)` — In-memory implementation (owns N MemoryDatabases)
const std = @import("std");
const adapter = @import("adapter.zig");
const Database = adapter.Database;
const WriteBatch = adapter.WriteBatch;
const DbSnapshot = adapter.DbSnapshot;
const Error = adapter.Error;
const memory = @import("memory.zig");
const MemoryDatabase = memory.MemoryDatabase;
const DbName = adapter.DbName;
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
    };
}

/// Cross-column write batch.
///
/// Mirrors Nethermind's `IColumnsWriteBatch<TKey>`. Wraps one `WriteBatch` per
/// column. Operations are accumulated per-column and committed together.
///
/// NOTE: Atomicity is per-column (each column's WriteBatch commits independently).
/// True cross-column atomicity requires the underlying backend to support it
/// (e.g., RocksDB WriteBatch across column families). For `MemoryDatabase`
/// backends, commits are sequential per-column.
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
        pub fn commit(self: *Self) Error!void {
            for (std.meta.tags(T)) |tag| {
                try self.batches.getPtr(tag).commit();
            }
        }

        /// Release all memory owned by all column batches.
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
        /// Uses `.receipts` as the `DbName` for all columns. The `DbName`
        /// identifies the logical database group; individual columns are
        /// distinguished by the enum key, not by `DbName`.
        pub fn init(allocator: std.mem.Allocator) Self {
            var databases: std.EnumArray(T, MemoryDatabase) = undefined;
            for (std.meta.tags(T)) |tag| {
                databases.set(tag, MemoryDatabase.init(allocator, .receipts));
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
    var snap0 = try db0.database().snapshot();
    var snap1 = try db1.database().snapshot();

    // Build ColumnDbSnapshot.
    // For the third column (blocks), create a trivial db + snapshot.
    var db2 = MemoryDatabase.init(std.testing.allocator, .receipts);
    defer db2.deinit();
    var snap2 = try db2.database().snapshot();

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

    var snap0 = try db0.database().snapshot();
    var snap1 = try db1.database().snapshot();
    var snap2 = try db2.database().snapshot();

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

// -- MemColumnsDb tests ------------------------------------------------------

test "MemColumnsDb init creates N databases" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator);
    defer mcdb.deinit();

    // Each column should have an empty MemoryDatabase.
    for (std.meta.tags(ReceiptsColumns)) |tag| {
        try std.testing.expect(mcdb.databases.getPtr(tag).get("nonexistent") == null);
    }
}

test "MemColumnsDb deinit frees all memory (leak check)" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator);

    // Write data to each column to ensure there's memory to free.
    var cdb = mcdb.columnsDb();
    try cdb.getColumnDb(.default).put("k", "v");
    try cdb.getColumnDb(.transactions).put("k", "v");
    try cdb.getColumnDb(.blocks).put("k", "v");

    // If deinit doesn't free properly, testing allocator will report a leak.
    mcdb.deinit();
}

test "MemColumnsDb columnsDb returns working interface" {
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator);
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
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator);
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
    var mcdb = MemColumnsDb(BlobTxsColumns).init(std.testing.allocator);
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
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator);
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
    var mcdb = MemColumnsDb(ReceiptsColumns).init(std.testing.allocator);
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
