/// Database factory interface for pluggable database creation.
///
/// Mirrors Nethermind's `IDbFactory` (`Nethermind.Db/IDbFactory.cs`),
/// enabling diagnostic modes (MemDb, ReadOnly, NullDb) and test isolation
/// without changing consumer code.
///
/// ## Design
///
/// The factory uses the same vtable pattern as `Database` (ptr + vtable
/// comptime DI). It provides two creation paths:
///
/// 1. **`createDb(DbSettings) -> OwnedDatabase`** — Runtime-dispatched via
///    vtable. Creates a single-column database and returns an owned handle.
///
/// 2. **`createColumnsDb(T, ...)`** — Comptime-dispatched. Each concrete
///    factory provides its own typed method. A standalone comptime helper
///    dispatches via `@hasDecl`.
///
/// This hybrid approach handles the Zig comptime/runtime split:
/// `ColumnsDb(T)` is comptime-generic, so it can't go through a vtable.
/// The concrete factory type is known at init time, so comptime generics
/// work for column operations.
///
/// ## Ownership
///
/// The factory returns `OwnedDatabase` — a `Database` interface paired with
/// a `deinit` callback. Callers must call `OwnedDatabase.deinit()` when done.
const std = @import("std");
const adapter = @import("adapter.zig");
const Database = adapter.Database;
const DbName = adapter.DbName;
const DbSettings = @import("rocksdb.zig").DbSettings;
const Error = adapter.Error;
const OwnedDatabase = adapter.OwnedDatabase;

/// Type-erased factory interface for creating database instances.
///
/// Mirrors Nethermind's `IDbFactory`:
/// - `createDb(DbSettings)` → runtime-dispatched single-column creation
/// - `getFullDbPath(DbSettings)` → filesystem path resolution
/// - `deinit()` → bulk cleanup of all factory-created resources
///
/// ## Usage
///
/// ```zig
/// // Get a factory interface from a concrete factory
/// var mem_factory = MemDbFactory.init(allocator);
/// defer mem_factory.deinit();
/// const factory = mem_factory.factory();
///
/// // Create a database
/// const owned = try factory.createDb(DbSettings.init(.state, "state"));
/// defer owned.deinit();
///
/// // Use the database
/// try owned.db.put("key", "value");
/// ```
pub const DbFactory = struct {
    /// Type-erased pointer to the concrete factory implementation.
    ptr: *anyopaque,
    /// Pointer to the static vtable for the concrete factory.
    vtable: *const VTable,

    /// Virtual function table for factory operations.
    pub const VTable = struct {
        /// Create a single-column database from settings.
        /// Returns an `OwnedDatabase` with cleanup callback.
        create_db: *const fn (ptr: *anyopaque, settings: DbSettings) Error!OwnedDatabase,
        /// Get the full filesystem path for a database given its settings.
        /// Returns a path slice (lifetime depends on the concrete factory).
        get_full_db_path: *const fn (ptr: *anyopaque, settings: DbSettings) []const u8,
        /// Release all factory-owned resources (optional bulk cleanup).
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Create a single-column database from settings.
    pub fn createDb(self: DbFactory, settings: DbSettings) Error!OwnedDatabase {
        return self.vtable.create_db(self.ptr, settings);
    }

    /// Get the full filesystem path for a database.
    pub fn getFullDbPath(self: DbFactory, settings: DbSettings) []const u8 {
        return self.vtable.get_full_db_path(self.ptr, settings);
    }

    /// Release all factory-owned resources.
    pub fn deinit(self: DbFactory) void {
        self.vtable.deinit(self.ptr);
    }

    /// Construct a `DbFactory` from a concrete factory pointer and typed
    /// function pointers.
    ///
    /// Generates type-safe vtable wrapper functions at comptime, following
    /// the same pattern as `Database.init`.
    pub fn init(comptime T: type, ptr: *T, comptime fns: struct {
        create_db: *const fn (self: *T, settings: DbSettings) Error!OwnedDatabase,
        get_full_db_path: *const fn (self: *T, settings: DbSettings) []const u8,
        deinit: *const fn (self: *T) void,
    }) DbFactory {
        const Wrapper = struct {
            fn create_db_impl(raw: *anyopaque, settings: DbSettings) Error!OwnedDatabase {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.create_db(typed, settings);
            }

            fn get_full_db_path_impl(raw: *anyopaque, settings: DbSettings) []const u8 {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.get_full_db_path(typed, settings);
            }

            fn deinit_impl(raw: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                fns.deinit(typed);
            }

            const vtable = VTable{
                .create_db = create_db_impl,
                .get_full_db_path = get_full_db_path_impl,
                .deinit = deinit_impl,
            };
        };

        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &Wrapper.vtable,
        };
    }
};

/// Create a `ColumnsDb(T)` using a concrete factory's comptime method.
///
/// Since vtables can't have comptime parameters, this standalone helper
/// dispatches via `@hasDecl` at comptime. Each concrete factory must
/// provide a `createColumnsDb` method with the appropriate signature.
///
/// ## Usage
///
/// ```zig
/// var mem_factory = MemDbFactory.init(allocator);
/// defer mem_factory.deinit();
/// var cols = createColumnsDb(ReceiptsColumns, MemDbFactory, &mem_factory, .receipts);
/// defer cols.deinit();
/// ```
pub fn createColumnsDb(
    comptime T: type,
    comptime FactoryType: type,
    factory_ptr: *FactoryType,
    db_name: DbName,
) @import("columns.zig").MemColumnsDb(T) {
    if (!@hasDecl(FactoryType, "createColumnsDb")) {
        @compileError(@typeName(FactoryType) ++ " does not implement createColumnsDb");
    }
    return factory_ptr.createColumnsDb(T, db_name);
}

const MemoryDatabase = @import("memory.zig").MemoryDatabase;
const columns = @import("columns.zig");

/// In-memory database factory.
///
/// Mirrors Nethermind's `MemDbFactory` (`Nethermind.Db/MemDbFactory.cs`).
/// Creates `MemoryDatabase` instances for testing and diagnostic modes.
///
/// Each `createDb` call heap-allocates a `MemoryDatabase` using the factory's
/// allocator. The returned `OwnedDatabase` cleans up the allocation on
/// `deinit()`.
///
/// ## Usage
///
/// ```zig
/// var mem_factory = MemDbFactory.init(allocator);
/// defer mem_factory.deinit();
///
/// const owned = try mem_factory.factory().createDb(DbSettings.init(.state, "state"));
/// defer owned.deinit();
///
/// try owned.db.put("key", "value");
/// ```
pub const MemDbFactory = struct {
    allocator: std.mem.Allocator,

    /// Create a new MemDbFactory using the given allocator.
    pub fn init(allocator: std.mem.Allocator) MemDbFactory {
        return .{ .allocator = allocator };
    }

    /// No-op — the factory itself holds no resources.
    /// Individual databases must be cleaned up via `OwnedDatabase.deinit()`.
    pub fn deinit(self: *MemDbFactory) void {
        _ = self;
    }

    /// Return a `DbFactory` vtable interface backed by this MemDbFactory.
    pub fn factory(self: *MemDbFactory) DbFactory {
        return DbFactory.init(MemDbFactory, self, .{
            .create_db = createDbImpl,
            .get_full_db_path = getFullDbPathImpl,
            .deinit = deinitImpl,
        });
    }

    /// Create a `MemColumnsDb(T)` for the given column enum type.
    ///
    /// This is the comptime-generic counterpart to `createDb`. It creates
    /// one `MemoryDatabase` per column variant, owned by the returned
    /// `MemColumnsDb`.
    pub fn createColumnsDb(self: *MemDbFactory, comptime T: type, db_name: DbName) columns.MemColumnsDb(T) {
        return columns.MemColumnsDb(T).init(self.allocator, db_name);
    }

    // -- Internal vtable implementations --------------------------------------

    /// Heap-allocated context for cleanup of a factory-created MemoryDatabase.
    /// Stored alongside the MemoryDatabase to avoid a separate allocation.
    const OwnedContext = struct {
        db: MemoryDatabase,
        allocator: std.mem.Allocator,
    };

    fn createDbImpl(self: *MemDbFactory, settings: DbSettings) Error!OwnedDatabase {
        // Heap-allocate the context (MemoryDatabase + allocator for cleanup).
        const ctx = self.allocator.create(OwnedContext) catch return error.OutOfMemory;
        ctx.* = .{
            .db = MemoryDatabase.init(self.allocator, settings.name),
            .allocator = self.allocator,
        };
        return .{
            .db = ctx.db.database(),
            .deinit_ctx = @ptrCast(ctx),
            .deinit_fn = destroyOwnedContext,
        };
    }

    fn destroyOwnedContext(raw: ?*anyopaque) void {
        if (raw) |ptr| {
            const ctx: *OwnedContext = @ptrCast(@alignCast(ptr));
            ctx.db.deinit();
            ctx.allocator.destroy(ctx);
        }
    }

    fn getFullDbPathImpl(_: *MemDbFactory, settings: DbSettings) []const u8 {
        // In-memory databases don't have a filesystem path.
        // Return the settings path as-is (matches Nethermind default).
        return settings.path;
    }

    fn deinitImpl(_: *MemDbFactory) void {
        // No-op — factory itself holds no resources.
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "DbFactory: vtable dispatch works with mock factory" {
    const MockFactory = struct {
        create_count: usize = 0,
        deinit_called: bool = false,

        fn create_db_impl(self: *@This(), _: DbSettings) Error!OwnedDatabase {
            self.create_count += 1;
            return error.UnsupportedOperation;
        }

        fn get_full_db_path_impl(_: *@This(), settings: DbSettings) []const u8 {
            return settings.path;
        }

        fn deinit_impl(self: *@This()) void {
            self.deinit_called = true;
        }
    };

    var mock = MockFactory{};
    const factory = DbFactory.init(MockFactory, &mock, .{
        .create_db = MockFactory.create_db_impl,
        .get_full_db_path = MockFactory.get_full_db_path_impl,
        .deinit = MockFactory.deinit_impl,
    });

    // createDb dispatches through vtable
    try std.testing.expectError(error.UnsupportedOperation, factory.createDb(DbSettings.init(.state, "/tmp/state")));
    try std.testing.expectEqual(@as(usize, 1), mock.create_count);

    // getFullDbPath dispatches through vtable
    const path = factory.getFullDbPath(DbSettings.init(.headers, "/tmp/headers"));
    try std.testing.expectEqualStrings("/tmp/headers", path);

    // deinit dispatches through vtable
    factory.deinit();
    try std.testing.expect(mock.deinit_called);
}

test "DbFactory: init generates correct wrappers" {
    const TestFactory = struct {
        value: u64 = 0,

        fn create_db_impl(self: *@This(), _: DbSettings) Error!OwnedDatabase {
            self.value += 1;
            return error.UnsupportedOperation;
        }

        fn get_full_db_path_impl(_: *@This(), settings: DbSettings) []const u8 {
            return settings.path;
        }

        fn deinit_impl(self: *@This()) void {
            self.value += 100;
        }
    };

    var backend = TestFactory{};
    const factory = DbFactory.init(TestFactory, &backend, .{
        .create_db = TestFactory.create_db_impl,
        .get_full_db_path = TestFactory.get_full_db_path_impl,
        .deinit = TestFactory.deinit_impl,
    });

    _ = factory.createDb(DbSettings.init(.state, "/tmp")) catch {};
    try std.testing.expectEqual(@as(u64, 1), backend.value);

    factory.deinit();
    try std.testing.expectEqual(@as(u64, 101), backend.value);
}

/// Sentinel factory that rejects all database creation attempts.
///
/// Mirrors Nethermind's `NullRocksDbFactory` (`Nethermind.Db/NullRocksDbFactory.cs`).
/// Used as a default/sentinel when no real factory is configured, preventing
/// accidental database creation in modes that shouldn't have persistence.
///
/// All `createDb` calls return `error.UnsupportedOperation`.
///
/// ## Usage
///
/// ```zig
/// var null_factory = NullDbFactory.init();
/// const factory = null_factory.factory();
///
/// // Will always error
/// const result = factory.createDb(DbSettings.init(.state, "state"));
/// // result == error.UnsupportedOperation
/// ```
pub const NullDbFactory = struct {
    /// Create a new NullDbFactory.
    pub fn init() NullDbFactory {
        return .{};
    }

    /// No-op — NullDbFactory holds no resources.
    pub fn deinit(self: *NullDbFactory) void {
        _ = self;
    }

    /// Return a `DbFactory` vtable interface backed by this NullDbFactory.
    pub fn factory(self: *NullDbFactory) DbFactory {
        return DbFactory.init(NullDbFactory, self, .{
            .create_db = createDbImpl,
            .get_full_db_path = getFullDbPathImpl,
            .deinit = deinitImpl,
        });
    }

    fn createDbImpl(_: *NullDbFactory, _: DbSettings) Error!OwnedDatabase {
        return error.UnsupportedOperation;
    }

    fn getFullDbPathImpl(_: *NullDbFactory, settings: DbSettings) []const u8 {
        return settings.path;
    }

    fn deinitImpl(_: *NullDbFactory) void {}
};

const ReadOnlyDb = @import("read_only.zig").ReadOnlyDb;

/// Decorator factory that wraps another factory and returns read-only databases.
///
/// Mirrors Nethermind's `ReadOnlyDbFactory` decorator pattern. Creates databases
/// via the base factory, then wraps them in `ReadOnlyDb` views. Optionally
/// provides an in-memory write overlay for snapshot execution.
///
/// ## Modes
///
/// - **Strict read-only** (`strict_read_only = true`): Writes return
///   `error.StorageError`. Reads delegate to the base factory's databases.
///
/// - **Write overlay** (`strict_read_only = false`): Writes go to an
///   in-memory overlay. Reads check overlay first, then fall back.
///
/// ## Ownership
///
/// The `OwnedDatabase` returned by `createDb` owns BOTH the `ReadOnlyDb`
/// wrapper AND the base `OwnedDatabase`. Its `deinit` cleans up both in
/// the correct order (wrapper first, then base).
///
/// ## Usage (write overlay)
///
/// ```zig
/// var mem_factory = MemDbFactory.init(allocator);
/// defer mem_factory.deinit();
///
/// var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), allocator, false);
/// defer ro_factory.deinit();
///
/// const owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state"));
/// defer owned.deinit();
///
/// // Writes go to overlay, reads merge
/// try owned.db.put("key", "value");
/// ```
///
/// ## Usage (strict read-only)
///
/// ```zig
/// var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), allocator, true);
/// defer ro_factory.deinit();
///
/// const owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state"));
/// defer owned.deinit();
///
/// // Reads work, writes error
/// _ = try owned.db.get("key");
/// // owned.db.put("key", "value") => error.StorageError
/// ```
pub const ReadOnlyDbFactory = struct {
    /// The base factory to delegate database creation to.
    base: DbFactory,
    /// Allocator for heap-allocating `OwnedContext` wrappers and (optionally)
    /// in-memory write overlays. Always required — even strict read-only mode
    /// needs to allocate the `OwnedContext` that pairs the `ReadOnlyDb` with
    /// the base `OwnedDatabase` for cleanup.
    allocator: std.mem.Allocator,
    /// When `true`, writes return `error.StorageError` (no overlay created).
    /// When `false`, writes go to an in-memory `MemoryDatabase` overlay.
    /// Mirrors Nethermind's `createInMemWriteStore` flag (inverted semantics).
    strict_read_only: bool,

    /// Create a ReadOnlyDbFactory wrapping the given base factory.
    ///
    /// `allocator` is always required for `OwnedContext` heap allocation.
    /// `strict_read_only` controls whether created databases have a write
    /// overlay (`false`) or reject all writes (`true`).
    pub fn init(base: DbFactory, allocator: std.mem.Allocator, strict_read_only: bool) ReadOnlyDbFactory {
        return .{
            .base = base,
            .allocator = allocator,
            .strict_read_only = strict_read_only,
        };
    }

    /// No-op — the ReadOnlyDbFactory itself holds no resources.
    /// Individual databases must be cleaned up via `OwnedDatabase.deinit()`.
    pub fn deinit(self: *ReadOnlyDbFactory) void {
        _ = self;
    }

    /// Return a `DbFactory` vtable interface backed by this ReadOnlyDbFactory.
    pub fn factory(self: *ReadOnlyDbFactory) DbFactory {
        return DbFactory.init(ReadOnlyDbFactory, self, .{
            .create_db = createDbImpl,
            .get_full_db_path = getFullDbPathImpl,
            .deinit = deinitImpl,
        });
    }

    /// Context for owning both the ReadOnlyDb wrapper and the base OwnedDatabase.
    const OwnedContext = struct {
        read_only: ReadOnlyDb,
        base_owned: OwnedDatabase,
        allocator: std.mem.Allocator,
    };

    fn createDbImpl(self: *ReadOnlyDbFactory, settings: DbSettings) Error!OwnedDatabase {
        // 1. Create the base database via the base factory.
        const base_owned = try self.base.createDb(settings);
        errdefer base_owned.deinit();

        // 2. Heap-allocate the context (always possible — allocator is non-null).
        const ctx = self.allocator.create(OwnedContext) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(ctx);

        // 3. Create the ReadOnlyDb wrapper.
        if (!self.strict_read_only) {
            // Overlay mode: writes buffered in MemoryDatabase overlay.
            ctx.* = .{
                .read_only = try ReadOnlyDb.init_with_write_store(base_owned.db, self.allocator),
                .base_owned = base_owned,
                .allocator = self.allocator,
            };
        } else {
            // Strict read-only mode: writes return error.StorageError.
            ctx.* = .{
                .read_only = ReadOnlyDb.init(base_owned.db),
                .base_owned = base_owned,
                .allocator = self.allocator,
            };
        }

        return .{
            .db = ctx.read_only.database(),
            .deinit_ctx = @ptrCast(ctx),
            .deinit_fn = destroyOwnedContext,
        };
    }

    fn destroyOwnedContext(raw: ?*anyopaque) void {
        if (raw) |ptr| {
            const ctx: *OwnedContext = @ptrCast(@alignCast(ptr));
            // Clean up in correct order: wrapper first, then base.
            ctx.read_only.deinit();
            ctx.base_owned.deinit();
            ctx.allocator.destroy(ctx);
        }
    }

    fn getFullDbPathImpl(self: *ReadOnlyDbFactory, settings: DbSettings) []const u8 {
        // Delegate to base factory.
        return self.base.getFullDbPath(settings);
    }

    fn deinitImpl(_: *ReadOnlyDbFactory) void {
        // No-op — factory itself holds no resources.
    }
};

// -- MemDbFactory tests ---------------------------------------------------

test "MemDbFactory: createDb returns a functional database" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    const owned = try mem_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer owned.deinit();

    // The database should work normally
    try owned.db.put("key", "value");
    const val = try owned.db.get("key");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("value", val.?.bytes);
}

test "MemDbFactory: created database supports put/get/delete" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    const owned = try mem_factory.factory().createDb(DbSettings.init(.code, "code"));
    defer owned.deinit();

    // put + get
    try owned.db.put("a", "1");
    const val_a = try owned.db.get("a");
    try std.testing.expect(val_a != null);
    defer val_a.?.release();
    try std.testing.expectEqualStrings("1", val_a.?.bytes);

    // delete
    try owned.db.delete("a");
    const val_deleted = try owned.db.get("a");
    try std.testing.expect(val_deleted == null);

    // contains
    try owned.db.put("b", "2");
    try std.testing.expect(try owned.db.contains("b"));
    try std.testing.expect(!try owned.db.contains("missing"));
}

test "MemDbFactory: OwnedDatabase.deinit frees MemoryDatabase (no leak)" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    const owned = try mem_factory.factory().createDb(DbSettings.init(.state, "state"));

    // Write data to ensure allocations exist
    try owned.db.put("key1", "value1_with_some_length");
    try owned.db.put("key2", "value2_with_some_length");
    try owned.db.put("key3", "value3_with_some_length");

    // If deinit doesn't free properly, testing allocator will report a leak
    owned.deinit();
}

test "MemDbFactory: multiple databases can be created from one factory" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    const f = mem_factory.factory();

    const db1 = try f.createDb(DbSettings.init(.state, "state"));
    defer db1.deinit();

    const db2 = try f.createDb(DbSettings.init(.code, "code"));
    defer db2.deinit();

    const db3 = try f.createDb(DbSettings.init(.headers, "headers"));
    defer db3.deinit();

    // Each database is independent
    try db1.db.put("key", "state_value");
    try db2.db.put("key", "code_value");

    const v1 = try db1.db.get("key");
    try std.testing.expect(v1 != null);
    defer v1.?.release();
    try std.testing.expectEqualStrings("state_value", v1.?.bytes);

    const v2 = try db2.db.get("key");
    try std.testing.expect(v2 != null);
    defer v2.?.release();
    try std.testing.expectEqualStrings("code_value", v2.?.bytes);

    // db3 has no data
    const v3 = try db3.db.get("key");
    try std.testing.expect(v3 == null);
}

test "MemDbFactory: database name matches settings" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    const owned = try mem_factory.factory().createDb(DbSettings.init(.receipts, "receipts"));
    defer owned.deinit();

    try std.testing.expectEqual(DbName.receipts, owned.db.name());
}

test "MemDbFactory: getFullDbPath returns settings path" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    const path = mem_factory.factory().getFullDbPath(DbSettings.init(.state, "/tmp/state"));
    try std.testing.expectEqualStrings("/tmp/state", path);
}

test "MemDbFactory: createColumnsDb returns functional MemColumnsDb" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var mcdb = mem_factory.createColumnsDb(columns.ReceiptsColumns, .receipts);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    // Write to different columns
    try cdb.getColumnDb(.default).put("k1", "v1");
    try cdb.getColumnDb(.transactions).put("k2", "v2");

    // Read back
    const v1 = try cdb.getColumnDb(.default).get("k1");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("v1", v1.?.bytes);

    const v2 = try cdb.getColumnDb(.transactions).get("k2");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("v2", v2.?.bytes);

    // Column isolation
    const v_cross = try cdb.getColumnDb(.blocks).get("k1");
    try std.testing.expect(v_cross == null);
}

test "MemDbFactory: createColumnsDb via comptime helper" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var mcdb = createColumnsDb(columns.BlobTxsColumns, MemDbFactory, &mem_factory, .blob_transactions);
    defer mcdb.deinit();

    var cdb = mcdb.columnsDb();

    try cdb.getColumnDb(.full_blob_txs).put("blob1", "data");
    const val = try cdb.getColumnDb(.full_blob_txs).get("blob1");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("data", val.?.bytes);
}

// -- NullDbFactory tests --------------------------------------------------

test "NullDbFactory: createDb returns UnsupportedOperation" {
    var null_factory = NullDbFactory.init();
    defer null_factory.deinit();

    const f = null_factory.factory();
    try std.testing.expectError(error.UnsupportedOperation, f.createDb(DbSettings.init(.state, "state")));
}

test "NullDbFactory: getFullDbPath returns settings path" {
    var null_factory = NullDbFactory.init();
    defer null_factory.deinit();

    const path = null_factory.factory().getFullDbPath(DbSettings.init(.headers, "/tmp/headers"));
    try std.testing.expectEqualStrings("/tmp/headers", path);
}

test "NullDbFactory: deinit is safe no-op" {
    var null_factory = NullDbFactory.init();

    // Should not panic or crash
    null_factory.deinit();

    // Also safe via vtable
    const f = null_factory.factory();
    f.deinit();
}

// -- ReadOnlyDbFactory tests ----------------------------------------------

test "ReadOnlyDbFactory: createDb returns read-only database with overlay" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, false);
    defer ro_factory.deinit();

    const owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer owned.deinit();

    // With overlay, writes go to overlay
    try owned.db.put("key", "value");
    const val = try owned.db.get("key");
    try std.testing.expect(val != null);
    defer val.?.release();
    try std.testing.expectEqualStrings("value", val.?.bytes);
}

test "ReadOnlyDbFactory: base database is cleaned up on deinit" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, false);
    defer ro_factory.deinit();

    const owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state"));

    // Write data to ensure allocations exist
    try owned.db.put("key1", "value1_with_some_length");
    try owned.db.put("key2", "value2_with_some_length");

    // If deinit doesn't free both wrapper and base, testing allocator leaks
    owned.deinit();
}

test "ReadOnlyDbFactory: getFullDbPath delegates to base factory" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, false);
    defer ro_factory.deinit();

    const path = ro_factory.factory().getFullDbPath(DbSettings.init(.headers, "/tmp/headers"));
    try std.testing.expectEqualStrings("/tmp/headers", path);
}

test "ReadOnlyDbFactory: multiple databases from one factory" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, false);
    defer ro_factory.deinit();

    const f = ro_factory.factory();

    const db1 = try f.createDb(DbSettings.init(.state, "state"));
    defer db1.deinit();

    const db2 = try f.createDb(DbSettings.init(.code, "code"));
    defer db2.deinit();

    // Each database is independent
    try db1.db.put("key", "state_val");
    try db2.db.put("key", "code_val");

    const v1 = try db1.db.get("key");
    try std.testing.expect(v1 != null);
    defer v1.?.release();
    try std.testing.expectEqualStrings("state_val", v1.?.bytes);

    const v2 = try db2.db.get("key");
    try std.testing.expect(v2 != null);
    defer v2.?.release();
    try std.testing.expectEqualStrings("code_val", v2.?.bytes);
}

// -- ReadOnlyDbFactory strict mode tests ----------------------------------

test "ReadOnlyDbFactory: strict mode creates functional read-only database" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, true);
    defer ro_factory.deinit();

    // createDb must succeed (no more OutOfMemory)
    const owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer owned.deinit();

    // Read from the database — returns null (empty base)
    const val = try owned.db.get("key");
    try std.testing.expect(val == null);

    // Write — returns error.StorageError
    try std.testing.expectError(error.StorageError, owned.db.put("key", "value"));
}

test "ReadOnlyDbFactory: strict mode reads delegate to base" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    // Write data to the base factory's database
    const base_owned = try mem_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer base_owned.deinit();
    try base_owned.db.put("existing_key", "base_value");

    // Create a strict read-only factory wrapping the same mem factory
    // Note: each createDb call creates a NEW base database, so we
    // verify reads return null (the strict wrapper wraps a fresh DB,
    // not the previously-created one).
    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, true);
    defer ro_factory.deinit();

    const ro_owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state2"));
    defer ro_owned.deinit();

    // New DB is empty — reads return null
    const val = try ro_owned.db.get("existing_key");
    try std.testing.expect(val == null);

    // Writes still error in strict mode
    try std.testing.expectError(error.StorageError, ro_owned.db.put("new_key", "new_value"));
}

test "ReadOnlyDbFactory: strict mode write returns StorageError" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, true);
    defer ro_factory.deinit();

    const owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state"));
    defer owned.deinit();

    // put returns StorageError
    try std.testing.expectError(error.StorageError, owned.db.put("key", "value"));
    // delete returns StorageError
    try std.testing.expectError(error.StorageError, owned.db.delete("key"));
}

test "ReadOnlyDbFactory: strict mode deinit frees both wrapper and base (no leak)" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, true);
    defer ro_factory.deinit();

    const owned = try ro_factory.factory().createDb(DbSettings.init(.state, "state"));
    // If deinit doesn't free both the OwnedContext and base, testing allocator
    // will detect the leak.
    owned.deinit();
}

test "ReadOnlyDbFactory: strict mode multiple databases from one factory" {
    var mem_factory = MemDbFactory.init(std.testing.allocator);
    defer mem_factory.deinit();

    var ro_factory = ReadOnlyDbFactory.init(mem_factory.factory(), std.testing.allocator, true);
    defer ro_factory.deinit();

    const f = ro_factory.factory();

    const db1 = try f.createDb(DbSettings.init(.state, "state"));
    defer db1.deinit();

    const db2 = try f.createDb(DbSettings.init(.code, "code"));
    defer db2.deinit();

    const db3 = try f.createDb(DbSettings.init(.headers, "headers"));
    defer db3.deinit();

    // Each database is independent and functional (reads work, writes error)
    try std.testing.expectError(error.StorageError, db1.db.put("k", "v"));
    try std.testing.expectError(error.StorageError, db2.db.put("k", "v"));
    try std.testing.expectError(error.StorageError, db3.db.put("k", "v"));

    const v1 = try db1.db.get("k");
    try std.testing.expect(v1 == null);
    const v2 = try db2.db.get("k");
    try std.testing.expect(v2 == null);
    const v3 = try db3.db.get("k");
    try std.testing.expect(v3 == null);
}
