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
