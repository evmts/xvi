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
