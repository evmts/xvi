/// Database abstraction layer for the Guillotine execution client.
///
/// Provides a backend-agnostic key-value storage interface modeled after
/// Nethermind's `IDb` / `IKeyValueStore` hierarchy. All persistent storage
/// (trie nodes, block data, receipts, etc.) goes through this interface.
///
/// ## Modules
///
/// - `Database` — Type-erased vtable interface for any KV backend.
/// - `WriteBatch` — Batched write operations with optional atomicity.
/// - `MemoryDatabase` — In-memory backend (for tests and ephemeral state).
/// - `NullDb` — Null object backend (reads return null, writes error).
/// - `ReadOnlyDb` — Read-only wrapper with optional in-memory overlay.
/// - `RocksDatabase` — RocksDB backend stub (not yet implemented).
/// - `DbSettings` — RocksDB configuration settings (name/path + flags + merge operators).
/// - `DbName` — Standard database partition names (matches Nethermind).
///
/// ## Architecture (Nethermind parity)
///
/// Nethermind separates `NullDb` (null object pattern, singleton) from
/// `DbOnTheRocks` (real RocksDB backend). This module follows the same
/// separation:
///   - `NullDb` — satisfies the Database interface without storing data.
///   - `RocksDatabase` — stub for future RocksDB FFI (all ops error).
///   - `MemoryDatabase` — in-memory storage for tests and ephemeral use.
///
/// ## Usage
///
/// ```zig
/// const db = @import("client/db/root.zig");
///
/// var mem = db.MemoryDatabase.init(allocator, .state);
/// defer mem.deinit();
///
/// const iface = mem.database();
/// try iface.put("key", "value");
/// ```
// Internal module imports — not part of the public API.
// Kept for `refAllDecls` in tests to ensure all sub-modules compile.
const adapter = @import("adapter.zig");
const memory = @import("memory.zig");
const null_db = @import("null.zig");
const rocksdb = @import("rocksdb.zig");
const read_only = @import("read_only.zig");
const provider = @import("provider.zig");
const ro_provider = @import("read_only_provider.zig");
const columns = @import("columns.zig");
const factory = @import("factory.zig");

// -- Public API: flat re-exports of all user-facing types -----------------

/// Type-erased vtable interface for any KV backend.
pub const Database = adapter.Database;
/// Batched write operations with optional atomicity.
pub const WriteBatch = adapter.WriteBatch;
/// Single write operation used in batched commits.
pub const WriteBatchOp = adapter.WriteBatchOp;
/// Standard database partition names (matches Nethermind).
pub const DbName = adapter.DbName;
/// Database error set for backend operations.
pub const Error = adapter.Error;
/// Read flags (Nethermind ReadFlags).
pub const ReadFlags = adapter.ReadFlags;
/// Write flags (Nethermind WriteFlags).
pub const WriteFlags = adapter.WriteFlags;
/// Database metrics (Nethermind DbMetric).
pub const DbMetric = adapter.DbMetric;
/// Borrowed DB value with release semantics.
pub const DbValue = adapter.DbValue;
/// Key/value entry used by iterators.
pub const DbEntry = adapter.DbEntry;
/// Type-erased DB iterator.
pub const DbIterator = adapter.DbIterator;
/// Type-erased DB snapshot.
pub const DbSnapshot = adapter.DbSnapshot;
/// In-memory backend (for tests and ephemeral state).
pub const MemoryDatabase = memory.MemoryDatabase;
/// Null object backend (reads return null, writes error).
pub const NullDb = null_db.NullDb;
/// RocksDB backend stub (not yet implemented).
pub const RocksDatabase = rocksdb.RocksDatabase;
/// RocksDB configuration settings (name/path + flags + merge operators).
pub const DbSettings = rocksdb.DbSettings;
/// Read-only wrapper with optional in-memory overlay.
pub const ReadOnlyDb = read_only.ReadOnlyDb;
/// Database provider (DbName → Database registry).
pub const DbProvider = provider.DbProvider;
/// Errors for DbProvider lookups.
pub const ProviderError = provider.ProviderError;
/// Read-only provider wrapper with optional per-DB overlay.
pub const ReadOnlyDbProvider = ro_provider.ReadOnlyDbProvider;
pub const ReadOnlyProviderError = ro_provider.ReadOnlyProviderError;
/// Comptime-generic column family database (mirrors Nethermind's `IColumnsDb<TKey>`).
pub const ColumnsDb = columns.ColumnsDb;
/// Cross-column write batch (mirrors Nethermind's `IColumnsWriteBatch<TKey>`).
pub const ColumnsWriteBatch = columns.ColumnsWriteBatch;
/// Cross-column snapshot (mirrors Nethermind's `IColumnDbSnapshot<TKey>`).
pub const ColumnDbSnapshot = columns.ColumnDbSnapshot;
/// In-memory column family database (mirrors Nethermind's `MemColumnsDb<TKey>`).
pub const MemColumnsDb = columns.MemColumnsDb;
/// Read-only column family database (mirrors Nethermind's `ReadOnlyColumnsDb<TKey>`).
pub const ReadOnlyColumnsDb = columns.ReadOnlyColumnsDb;
/// Column families for receipt storage.
pub const ReceiptsColumns = columns.ReceiptsColumns;
/// Column families for blob transaction storage (EIP-4844).
pub const BlobTxsColumns = columns.BlobTxsColumns;
/// Owned database handle with cleanup callback (returned by factories).
pub const OwnedDatabase = adapter.OwnedDatabase;
/// Type-erased database factory interface (mirrors Nethermind's `IDbFactory`).
pub const DbFactory = factory.DbFactory;
/// In-memory database factory for testing and diagnostic modes.
pub const MemDbFactory = factory.MemDbFactory;
/// Sentinel factory that rejects all creation attempts.
pub const NullDbFactory = factory.NullDbFactory;
/// Decorator factory returning read-only database views.
pub const ReadOnlyDbFactory = factory.ReadOnlyDbFactory;
/// Comptime helper for creating column databases via a concrete factory.
pub const createColumnsDb = factory.createColumnsDb;

const std = @import("std");

test {
    // Ensure all sub-modules compile and their tests run.
    std.testing.refAllDecls(@This());
}

test "integration: MemDbFactory populates DbProvider" {
    const testing = std.testing;

    var mem_factory = MemDbFactory.init(testing.allocator);
    defer mem_factory.deinit();

    var prov = DbProvider.init();

    // Create databases via factory
    const state_db = try mem_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer state_db.deinit();
    prov.register(.state, state_db.db);

    const code_db = try mem_factory.factory().createDb(DbSettings.init(.code, "code"));
    defer code_db.deinit();
    prov.register(.code, code_db.db);

    // Use provider as normal
    const db = try prov.get(.state);
    try db.put("key", "value");
    const val = try db.get("key");
    try testing.expect(val != null);
    defer val.?.release();
    try testing.expectEqualStrings("value", val.?.bytes);

    // Code db is independent
    const code = try prov.get(.code);
    try code.put("code_key", "bytecode");
    const code_val = try code.get("code_key");
    try testing.expect(code_val != null);
    defer code_val.?.release();
    try testing.expectEqualStrings("bytecode", code_val.?.bytes);

    // State db doesn't have code_key
    const cross = try db.get("code_key");
    try testing.expect(cross == null);
}

test "integration: ReadOnlyDbFactory wraps MemDbFactory" {
    const testing = std.testing;

    var mem_factory = MemDbFactory.init(testing.allocator);
    defer mem_factory.deinit();

    // Write data to a base database
    const base_db = try mem_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer base_db.deinit();
    try base_db.db.put("existing", "original");

    // Create a read-only factory wrapping the mem factory
    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), testing.allocator);
    defer ro_factory.deinit();

    // Create a read-only database
    const ro_owned = try ro_factory.factory().createDb(DbSettings.init(.headers, "headers"));
    defer ro_owned.deinit();

    // Read-only db starts empty (it's a new database, not wrapping base_db)
    const val = try ro_owned.db.get("existing");
    try testing.expect(val == null);

    // But overlay writes work
    try ro_owned.db.put("new_key", "new_value");
    const new_val = try ro_owned.db.get("new_key");
    try testing.expect(new_val != null);
    defer new_val.?.release();
    try testing.expectEqualStrings("new_value", new_val.?.bytes);
}

test "integration: factory swap at startup (MemDb vs NullDb)" {
    const testing = std.testing;

    // Simulate startup config: choose factory based on mode
    const use_mem = true;

    var mem_factory = MemDbFactory.init(testing.allocator);
    defer mem_factory.deinit();

    var null_factory = NullDbFactory.init();
    defer null_factory.deinit();

    // Select factory at "startup"
    const f: DbFactory = if (use_mem) mem_factory.factory() else null_factory.factory();

    // Consumer code doesn't know which factory was chosen
    const result = f.createDb(DbSettings.init(.state, "state"));
    if (result) |owned| {
        defer owned.deinit();
        try owned.db.put("key", "value");
        const val = try owned.db.get("key");
        try testing.expect(val != null);
        defer val.?.release();
        try testing.expectEqualStrings("value", val.?.bytes);
    } else |_| {
        // NullDbFactory would error here
        try testing.expect(!use_mem);
    }
}
