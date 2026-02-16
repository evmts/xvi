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
