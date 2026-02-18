/// Database adapter interface for persistent key-value storage.
///
/// Follows the vtable pattern from `src/host.zig` (ptr + vtable comptime DI).
/// Modeled after Nethermind's IKeyValueStore / IDb interface hierarchy,
/// simplified for Zig: a single `Database` struct that combines read + write
/// operations behind a type-erased vtable.
///
/// All operations use byte slices (`[]const u8`) as keys and optional byte
/// slices as values. A `get` returning `null` means "key not found".
/// A `put` with a `null` value is equivalent to `delete` (Nethermind pattern).
///
/// Error handling: all operations return error unions — never use `catch {}`.
///
/// ## Relationship to Voltaire
///
/// This module provides a *low-level persistence abstraction* (raw key-value
/// storage for trie nodes, block data, receipts, etc.) that sits below
/// Voltaire's state management layer. Voltaire's `StateManager`,
/// `JournaledState`, and cache types (AccountCache, StorageCache,
/// ContractCache) operate on typed, in-memory state and delegate to this
/// persistence layer for durable storage. The two are complementary:
///
///   Voltaire StateManager → (typed state ops) → DB adapter → (raw KV) → backend
///
/// The `Database` / `WriteBatch` / `DbName` types defined here are
/// intentionally backend-agnostic — Voltaire does not provide a raw KV
/// persistence interface, so this abstraction fills that gap.
///
/// NOTE: Voltaire's `Bytes` primitive is a helper module (operations on slices),
/// not a distinct byte-slice type. This layer therefore accepts `[]const u8`
/// to support variable-length keys/values across all column families. Callers
/// should use Voltaire fixed-size primitives (e.g. `Bytes32`, `Hash`, `Address`)
/// and serialize them into byte slices before hitting this interface.
const std = @import("std");

/// Errors that database operations can produce.
///
/// `OutOfMemory` is kept separate (via Zig's error union mechanism) so that
/// callers can distinguish allocation failures from backend I/O errors.
pub const Error = error{
    /// The underlying storage backend encountered an I/O or corruption error.
    StorageError,
    /// The key was too large for the backend to handle.
    KeyTooLarge,
    /// The value was too large for the backend to handle.
    ValueTooLarge,
    /// The database has been closed or is in an invalid state.
    DatabaseClosed,
    /// The backend does not support the requested operation.
    UnsupportedOperation,
    /// Allocation failure — propagated directly, never masked as StorageError.
    OutOfMemory,
};

/// Standard database column/partition names, mirroring Nethermind's `DbNames`.
///
/// Each name identifies a logical partition of the database. Backends may
/// implement these as separate column families (RocksDB) or separate
/// HashMap instances (MemoryDatabase).
///
/// Matches Nethermind's `DbNames` constants from
/// `Nethermind.Db/DbNames.cs` — all 15 database names are included.
pub const DbName = enum {
    /// World state (account trie nodes)
    state,
    /// Contract storage (storage trie nodes)
    storage,
    /// Contract bytecode
    code,
    /// Block bodies (transactions + ommers)
    blocks,
    /// Block headers
    headers,
    /// Block number → block hash mapping
    block_numbers,
    /// Transaction receipts
    receipts,
    /// Block metadata (total difficulty, etc.)
    block_infos,
    /// Invalid / rejected blocks
    bad_blocks,
    /// Bloom filter index
    bloom,
    /// Client metadata (sync state, etc.)
    metadata,
    /// EIP-4844 blob transactions
    blob_transactions,
    /// Discovery Protocol v4 node cache (devp2p)
    discovery_nodes,
    /// Discovery Protocol v5 node cache (devp2p, UDP-based)
    discovery_v5_nodes,
    /// RLPx peer database (P2P networking)
    peers,

    /// Returns the string representation matching Nethermind's DbNames constants.
    pub fn to_string(self: DbName) []const u8 {
        return switch (self) {
            .state => "state",
            .storage => "storage",
            .code => "code",
            .blocks => "blocks",
            .headers => "headers",
            .block_numbers => "blockNumbers",
            .block_infos => "blockInfos",
            .receipts => "receipts",
            .bad_blocks => "badBlocks",
            .bloom => "bloom",
            .metadata => "metadata",
            .blob_transactions => "blobTransactions",
            .discovery_nodes => "discoveryNodes",
            .discovery_v5_nodes => "discoveryV5Nodes",
            .peers => "peers",
        };
    }
};

/// Read flags (Nethermind ReadFlags) — backend optimization hints.
pub const ReadFlags = struct {
    bits: u8,

    pub const none = ReadFlags{ .bits = 0 };
    pub const hint_cache_miss = ReadFlags{ .bits = 1 };
    pub const hint_read_ahead = ReadFlags{ .bits = 2 };
    pub const hint_read_ahead2 = ReadFlags{ .bits = 4 };
    pub const hint_read_ahead3 = ReadFlags{ .bits = 8 };
    pub const skip_duplicate_read = ReadFlags{ .bits = 16 };

    pub fn merge(self: ReadFlags, other: ReadFlags) ReadFlags {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn has(self: ReadFlags, other: ReadFlags) bool {
        return (self.bits & other.bits) == other.bits;
    }
};

/// Write flags (Nethermind WriteFlags) — backend optimization hints.
pub const WriteFlags = struct {
    bits: u8,

    pub const none = WriteFlags{ .bits = 0 };
    pub const low_priority = WriteFlags{ .bits = 1 };
    pub const disable_wal = WriteFlags{ .bits = 2 };
    pub const low_priority_and_no_wal = WriteFlags{
        .bits = low_priority.bits | disable_wal.bits,
    };

    pub fn merge(self: WriteFlags, other: WriteFlags) WriteFlags {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn has(self: WriteFlags, other: WriteFlags) bool {
        return (self.bits & other.bits) == other.bits;
    }
};

/// Database metrics (Nethermind DbMetric).
pub const DbMetric = struct {
    size: u64 = 0,
    cache_size: u64 = 0,
    index_size: u64 = 0,
    memtable_size: u64 = 0,
    total_reads: u64 = 0,
    total_writes: u64 = 0,
};

/// Release callback for DB values owned by the backend.
pub const ReleaseFn = *const fn (ctx: ?*anyopaque, bytes: []const u8) void;

/// Borrowed DB value with optional release hook.
pub const DbValue = struct {
    bytes: []const u8,
    release_ctx: ?*anyopaque = null,
    release_fn: ?ReleaseFn = null,

    pub fn release(self: DbValue) void {
        if (self.release_fn) |func| {
            func(self.release_ctx, self.bytes);
        }
    }

    pub fn borrowed(bytes: []const u8) DbValue {
        return .{ .bytes = bytes };
    }
};

/// Key/value entry used by iterators.
pub const DbEntry = struct {
    key: DbValue,
    value: DbValue,

    pub fn release(self: DbEntry) void {
        self.key.release();
        self.value.release();
    }
};

/// Type-erased DB iterator.
pub const DbIterator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) Error!?DbEntry,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn next(self: *DbIterator) Error!?DbEntry {
        return self.vtable.next(self.ptr);
    }

    pub fn deinit(self: *DbIterator) void {
        self.vtable.deinit(self.ptr);
    }

    /// Create a type-erased `DbIterator` from a typed pointer and vtable functions.
    ///
    /// Accepts `*const T` so callers may pass pointers to immutable sentinels
    /// (e.g., `NullDb.empty_iterator`). The pointer is stored internally as
    /// `*anyopaque` via `@constCast`.
    ///
    /// ## Safety
    ///
    /// If `ptr` refers to truly immutable (comptime-const or read-only) memory,
    /// `next_fn` and `deinit_fn` **must not** mutate through their `*T` parameter.
    /// Violating this invariant is undefined behavior. All current callers
    /// (NullDb, MemoryDatabase) satisfy this contract.
    pub fn init(
        comptime T: type,
        ptr: *const T,
        comptime next_fn: *const fn (ptr: *T) Error!?DbEntry,
        comptime deinit_fn: *const fn (ptr: *T) void,
    ) DbIterator {
        const Wrapper = struct {
            fn next_impl(raw: *anyopaque) Error!?DbEntry {
                const typed: *T = @ptrCast(@alignCast(raw));
                return next_fn(typed);
            }

            fn deinit_impl(raw: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                deinit_fn(typed);
            }

            const vtable = VTable{
                .next = next_impl,
                .deinit = deinit_impl,
            };
        };

        return .{
            .ptr = @ptrCast(@constCast(ptr)),
            .vtable = &Wrapper.vtable,
        };
    }
};

/// Type-erased DB snapshot.
pub const DbSnapshot = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, key: []const u8, flags: ReadFlags) Error!?DbValue,
        contains: *const fn (ptr: *anyopaque, key: []const u8) Error!bool,
        iterator: ?*const fn (ptr: *anyopaque, ordered: bool) Error!DbIterator,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn get(self: *const DbSnapshot, key: []const u8, flags: ReadFlags) Error!?DbValue {
        return self.vtable.get(self.ptr, key, flags);
    }

    pub fn contains(self: *const DbSnapshot, key: []const u8) Error!bool {
        return self.vtable.contains(self.ptr, key);
    }

    pub fn iterator(self: *const DbSnapshot, ordered: bool) Error!DbIterator {
        if (self.vtable.iterator) |iter_fn| {
            return iter_fn(self.ptr, ordered);
        }
        return error.UnsupportedOperation;
    }

    pub fn deinit(self: *const DbSnapshot) void {
        self.vtable.deinit(self.ptr);
    }

    /// Create a type-erased `DbSnapshot` from a typed pointer and vtable functions.
    ///
    /// Accepts `*const T` so callers may pass pointers to immutable sentinels
    /// (e.g., `NullDb.null_snapshot`). The pointer is stored internally as
    /// `*anyopaque` via `@constCast`.
    ///
    /// ## Safety
    ///
    /// If `ptr` refers to truly immutable (comptime-const or read-only) memory,
    /// the vtable functions (`get_fn`, `contains_fn`, `iterator_fn`, `deinit_fn`)
    /// **must not** mutate through their `*T` parameter. Violating this invariant
    /// is undefined behavior. All current callers (NullDb, MemoryDatabase)
    /// satisfy this contract.
    pub fn init(
        comptime T: type,
        ptr: *const T,
        comptime get_fn: *const fn (ptr: *T, key: []const u8, flags: ReadFlags) Error!?DbValue,
        comptime contains_fn: *const fn (ptr: *T, key: []const u8) Error!bool,
        comptime iterator_fn: ?*const fn (ptr: *T, ordered: bool) Error!DbIterator,
        comptime deinit_fn: *const fn (ptr: *T) void,
    ) DbSnapshot {
        const Wrapper = struct {
            fn get_impl(raw: *anyopaque, key: []const u8, flags: ReadFlags) Error!?DbValue {
                const typed: *T = @ptrCast(@alignCast(raw));
                return get_fn(typed, key, flags);
            }

            fn contains_impl(raw: *anyopaque, key: []const u8) Error!bool {
                const typed: *T = @ptrCast(@alignCast(raw));
                return contains_fn(typed, key);
            }

            fn iterator_impl(raw: *anyopaque, ordered: bool) Error!DbIterator {
                const typed: *T = @ptrCast(@alignCast(raw));
                const iter_fn = iterator_fn orelse return error.UnsupportedOperation;
                return iter_fn(typed, ordered);
            }

            fn deinit_impl(raw: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                deinit_fn(typed);
            }

            const vtable = VTable{
                .get = get_impl,
                .contains = contains_impl,
                .iterator = if (iterator_fn == null) null else iterator_impl,
                .deinit = deinit_impl,
            };
        };

        return .{
            .ptr = @ptrCast(@constCast(ptr)),
            .vtable = &Wrapper.vtable,
        };
    }
};

/// Generic key-value database interface using type-erased vtable dispatch.
///
/// This is the fundamental storage abstraction for the Guillotine execution
/// client. All persistent storage (trie nodes, block data, receipts, etc.)
/// goes through this interface.
///
/// ## Usage
///
/// ```zig
/// // Create a concrete backend (e.g. MemoryDatabase)
/// var mem_db = try MemoryDatabase.init(allocator);
/// defer mem_db.deinit();
///
/// // Get the type-erased Database interface
/// const db = mem_db.database();
///
/// // Use the interface
/// try db.put("key", "value");
/// const val = try db.get("key"); // returns ?DbValue
/// ```
pub const Database = struct {
    /// Type-erased pointer to the concrete backend implementation.
    ptr: *anyopaque,
    /// Pointer to the static vtable for the concrete backend.
    vtable: *const VTable,

    /// Virtual function table for database operations.
    ///
    /// Mirrors Nethermind's IReadOnlyKeyValueStore + IWriteOnlyKeyValueStore,
    /// combined into a single vtable for simplicity.
    pub const VTable = struct {
        /// Name of the database (column family).
        name: *const fn (ptr: *anyopaque) DbName,

        /// Retrieve the value associated with `key`.
        /// Returns `null` if the key does not exist.
        /// The returned slice is owned by the database and valid until
        /// the next mutation or database destruction.
        get: *const fn (ptr: *anyopaque, key: []const u8, flags: ReadFlags) Error!?DbValue,

        /// Store a key-value pair. If `value` is `null`, this is equivalent
        /// to calling `delete`. Overwrites any existing value for the key.
        /// Input slices are caller-owned and only valid for the duration
        /// of the call; implementations must copy if they need to retain them.
        put: *const fn (ptr: *anyopaque, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void,

        /// Remove the entry for `key`. No-op if the key does not exist.
        delete: *const fn (ptr: *anyopaque, key: []const u8, flags: WriteFlags) Error!void,

        /// Check whether `key` exists in the database.
        contains: *const fn (ptr: *anyopaque, key: []const u8) Error!bool,

        /// Iterate over all key/value entries.
        iterator: *const fn (ptr: *anyopaque, ordered: bool) Error!DbIterator,

        /// Create a snapshot for consistent reads.
        snapshot: *const fn (ptr: *anyopaque) Error!DbSnapshot,

        /// Flush pending writes to storage.
        flush: *const fn (ptr: *anyopaque, only_wal: bool) Error!void,

        /// Clear all entries in the database.
        clear: *const fn (ptr: *anyopaque) Error!void,

        /// Compact database storage.
        compact: *const fn (ptr: *anyopaque) Error!void,

        /// Gather diagnostic metrics.
        gather_metric: *const fn (ptr: *anyopaque) Error!DbMetric,

        /// Apply a batch of write operations atomically.
        ///
        /// Backends that support native batch writes (e.g. RocksDB WriteBatch)
        /// should implement this to provide true all-or-nothing semantics.
        /// If `null`, WriteBatch.commit will fall back to sequential application
        /// with best-effort error reporting (partial writes possible on error).
        ///
        /// On success, all operations in `ops` are applied. On error, the
        /// backend must guarantee that NO operations were applied (rollback).
        /// The `ops` slice and embedded key/value slices are caller-owned and
        /// only valid for the duration of the call; implementations must
        /// consume/copy synchronously and must not retain references.
        write_batch: ?*const fn (ptr: *anyopaque, ops: []const WriteBatchOp) Error!void = null,

        /// Apply a merge operation (RocksDB native merge operator).
        ///
        /// Backends that support native merge operators (e.g., RocksDB) should
        /// implement this for efficient read-modify-write without read-before-write.
        /// If `null`, merge operations will return `error.UnsupportedOperation`.
        ///
        /// Mirrors Nethermind's `IMergeableKeyValueStore.Merge(key, value, flags)`.
        merge: ?*const fn (ptr: *anyopaque, key: []const u8, value: []const u8, flags: WriteFlags) Error!void = null,

        /// Retrieve multiple values in a single batch operation.
        ///
        /// Backends that support native multi-key reads (e.g., RocksDB MultiGet)
        /// should implement this for batched I/O efficiency.
        /// If `null`, `Database.multi_get()` falls back to sequential `get()` calls.
        ///
        /// `keys` and `results` must have the same length. The backend fills
        /// `results[i]` with the value for `keys[i]` (null if not found).
        /// Caller owns both slices and must release each non-null DbValue.
        ///
        /// Mirrors Nethermind's `IDb.this[byte[][] keys]` indexer.
        multi_get: ?*const fn (ptr: *anyopaque, keys: []const []const u8, results: []?DbValue, flags: ReadFlags) Error!void = null,
    };

    /// Return the database name (column family).
    pub fn name(self: Database) DbName {
        return self.vtable.name(self.ptr);
    }

    /// Retrieve the value associated with `key`.
    /// Returns `null` if the key does not exist.
    pub fn get(self: Database, key: []const u8) Error!?DbValue {
        return self.get_with_flags(key, .none);
    }

    /// Retrieve the value associated with `key` with explicit read flags.
    pub fn get_with_flags(self: Database, key: []const u8, flags: ReadFlags) Error!?DbValue {
        return self.vtable.get(self.ptr, key, flags);
    }

    /// Store a key-value pair. If `value` is `null`, this is equivalent
    /// to calling `delete`.
    pub fn put(self: Database, key: []const u8, value: ?[]const u8) Error!void {
        return self.put_with_flags(key, value, .none);
    }

    /// Store a key-value pair with explicit write flags.
    pub fn put_with_flags(self: Database, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void {
        return self.vtable.put(self.ptr, key, value, flags);
    }

    /// Remove the entry for `key`. No-op if the key does not exist.
    pub fn delete(self: Database, key: []const u8) Error!void {
        return self.delete_with_flags(key, .none);
    }

    /// Remove the entry for `key` with explicit write flags.
    pub fn delete_with_flags(self: Database, key: []const u8, flags: WriteFlags) Error!void {
        return self.vtable.delete(self.ptr, key, flags);
    }

    /// Check whether `key` exists in the database.
    pub fn contains(self: Database, key: []const u8) Error!bool {
        return self.vtable.contains(self.ptr, key);
    }

    /// Iterate over all entries in the database.
    pub fn iterator(self: Database, ordered: bool) Error!DbIterator {
        return self.vtable.iterator(self.ptr, ordered);
    }

    /// Create a snapshot for consistent reads.
    pub fn snapshot(self: Database) Error!DbSnapshot {
        return self.vtable.snapshot(self.ptr);
    }

    /// Flush pending writes to storage.
    pub fn flush(self: Database, only_wal: bool) Error!void {
        return self.vtable.flush(self.ptr, only_wal);
    }

    /// Clear all entries in the database.
    pub fn clear(self: Database) Error!void {
        return self.vtable.clear(self.ptr);
    }

    /// Compact database storage.
    pub fn compact(self: Database) Error!void {
        return self.vtable.compact(self.ptr);
    }

    /// Gather diagnostic metrics.
    pub fn gather_metric(self: Database) Error!DbMetric {
        return self.vtable.gather_metric(self.ptr);
    }

    /// Returns true if the backend provides an atomic `write_batch` implementation.
    pub fn supports_write_batch(self: Database) bool {
        return self.vtable.write_batch != null;
    }

    /// Create a new write batch targeting this database.
    ///
    /// Mirrors Nethermind's `StartWriteBatch()` convenience API.
    pub fn start_write_batch(self: Database, allocator: std.mem.Allocator) WriteBatch {
        return WriteBatch.init(allocator, self);
    }

    /// Returns true if the backend supports the `merge` operation.
    ///
    /// Backends that support native merge operators (e.g., RocksDB) set the
    /// `merge` vtable entry. In-memory and null backends leave it as `null`.
    pub fn supports_merge(self: Database) bool {
        return self.vtable.merge != null;
    }

    /// Apply a merge operation with default write flags.
    ///
    /// Returns `error.UnsupportedOperation` if the backend does not support merge.
    /// Mirrors Nethermind's `IMergeableKeyValueStore.Merge(key, value)`.
    pub fn merge(self: Database, key: []const u8, value: []const u8) Error!void {
        return self.merge_with_flags(key, value, WriteFlags.none);
    }

    /// Apply a merge operation with explicit write flags.
    ///
    /// Returns `error.UnsupportedOperation` if the backend does not support merge.
    /// Mirrors Nethermind's `IMergeableKeyValueStore.Merge(key, value, flags)`.
    pub fn merge_with_flags(self: Database, key: []const u8, value: []const u8, flags: WriteFlags) Error!void {
        const merge_fn = self.vtable.merge orelse return error.UnsupportedOperation;
        return merge_fn(self.ptr, key, value, flags);
    }

    /// Returns true if the backend provides a native `multi_get` implementation.
    pub fn supports_multi_get(self: Database) bool {
        return self.vtable.multi_get != null;
    }

    /// Retrieve multiple values in a single batch with default read flags.
    ///
    /// If the backend supports native multi-get, dispatches directly.
    /// Otherwise, falls back to sequential `get()` calls.
    ///
    /// `keys.len` must equal `results.len`. On return, `results[i]` is
    /// the value for `keys[i]` (null if not found). Caller must release
    /// each non-null DbValue.
    pub fn multi_get(self: Database, keys: []const []const u8, results: []?DbValue) Error!void {
        return self.multi_get_with_flags(keys, results, ReadFlags.none);
    }

    /// Retrieve multiple values in a single batch with explicit read flags.
    pub fn multi_get_with_flags(self: Database, keys: []const []const u8, results: []?DbValue, flags: ReadFlags) Error!void {
        std.debug.assert(keys.len == results.len);
        if (self.vtable.multi_get) |mg_fn| {
            return mg_fn(self.ptr, keys, results, flags);
        }
        // Sequential fallback — same pattern as WriteBatch sequential fallback.
        for (keys, 0..) |key, i| {
            results[i] = try self.get_with_flags(key, flags);
        }
    }

    /// Construct a `Database` from a concrete backend pointer and typed function pointers.
    ///
    /// Generates type-safe vtable wrapper functions at comptime, eliminating
    /// the need for manual `@ptrCast`/`@alignCast` boilerplate in every backend.
    /// Follows the same pattern as `DbIterator.init` and `DbSnapshot.init`.
    ///
    /// ## Usage
    ///
    /// ```zig
    /// pub fn database(self: *MyBackend) Database {
    ///     return Database.init(MyBackend, self, .{
    ///         .name = name_impl,
    ///         .get = get_impl,
    ///         .put = put_impl,
    ///         .delete = delete_impl,
    ///         .contains = contains_impl,
    ///         .iterator = iterator_impl,
    ///         .snapshot = snapshot_impl,
    ///         .flush = flush_impl,
    ///         .clear = clear_impl,
    ///         .compact = compact_impl,
    ///         .gather_metric = gather_metric_impl,
    ///     });
    /// }
    /// ```
    pub fn init(comptime T: type, ptr: *T, comptime fns: struct {
        name: *const fn (self: *T) DbName,
        get: *const fn (self: *T, key: []const u8, flags: ReadFlags) Error!?DbValue,
        put: *const fn (self: *T, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void,
        delete: *const fn (self: *T, key: []const u8, flags: WriteFlags) Error!void,
        contains: *const fn (self: *T, key: []const u8) Error!bool,
        iterator: *const fn (self: *T, ordered: bool) Error!DbIterator,
        snapshot: *const fn (self: *T) Error!DbSnapshot,
        flush: *const fn (self: *T, only_wal: bool) Error!void,
        clear: *const fn (self: *T) Error!void,
        compact: *const fn (self: *T) Error!void,
        gather_metric: *const fn (self: *T) Error!DbMetric,
        write_batch: ?*const fn (self: *T, ops: []const WriteBatchOp) Error!void = null,
        merge: ?*const fn (self: *T, key: []const u8, value: []const u8, flags: WriteFlags) Error!void = null,
        multi_get: ?*const fn (self: *T, keys: []const []const u8, results: []?DbValue, flags: ReadFlags) Error!void = null,
    }) Database {
        const Wrapper = struct {
            fn name_impl(raw: *anyopaque) DbName {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.name(typed);
            }

            fn get_impl(raw: *anyopaque, key: []const u8, flags: ReadFlags) Error!?DbValue {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.get(typed, key, flags);
            }

            fn put_impl(raw: *anyopaque, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.put(typed, key, value, flags);
            }

            fn delete_impl(raw: *anyopaque, key: []const u8, flags: WriteFlags) Error!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.delete(typed, key, flags);
            }

            fn contains_impl(raw: *anyopaque, key: []const u8) Error!bool {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.contains(typed, key);
            }

            fn iterator_impl(raw: *anyopaque, ordered: bool) Error!DbIterator {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.iterator(typed, ordered);
            }

            fn snapshot_impl(raw: *anyopaque) Error!DbSnapshot {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.snapshot(typed);
            }

            fn flush_impl(raw: *anyopaque, only_wal: bool) Error!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.flush(typed, only_wal);
            }

            fn clear_impl(raw: *anyopaque) Error!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.clear(typed);
            }

            fn compact_impl(raw: *anyopaque) Error!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.compact(typed);
            }

            fn gather_metric_impl(raw: *anyopaque) Error!DbMetric {
                const typed: *T = @ptrCast(@alignCast(raw));
                return fns.gather_metric(typed);
            }

            fn write_batch_impl(raw: *anyopaque, ops: []const WriteBatchOp) Error!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                const wb_fn = fns.write_batch orelse unreachable;
                return wb_fn(typed, ops);
            }

            fn merge_impl(raw: *anyopaque, key: []const u8, value: []const u8, flags: WriteFlags) Error!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                const merge_fn = fns.merge orelse unreachable;
                return merge_fn(typed, key, value, flags);
            }

            fn multi_get_impl(raw: *anyopaque, keys: []const []const u8, results: []?DbValue, flags: ReadFlags) Error!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                const mg_fn = fns.multi_get orelse unreachable;
                return mg_fn(typed, keys, results, flags);
            }

            const vtable = VTable{
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
                .write_batch = if (fns.write_batch == null) null else write_batch_impl,
                .merge = if (fns.merge == null) null else merge_impl,
                .multi_get = if (fns.multi_get == null) null else multi_get_impl,
            };
        };

        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &Wrapper.vtable,
        };
    }
};

/// A Database interface paired with an ownership handle for cleanup.
///
/// Returned by factory methods when the factory owns the backing storage.
/// Callers must call `deinit()` when done, or rely on the factory's
/// bulk cleanup if using arena-based allocation.
///
/// Mirrors the ownership pattern needed by Nethermind's `IDbFactory.CreateDb()`,
/// where the factory creates and owns the database instance, but returns an
/// interface handle to the caller.
pub const OwnedDatabase = struct {
    /// Type-erased Database interface (non-owning handle into the backing storage).
    db: Database,
    /// Opaque context pointer passed to the deinit callback (e.g., the allocator or factory).
    deinit_ctx: ?*anyopaque = null,
    /// Cleanup callback that releases the backing storage.
    deinit_fn: ?*const fn (ctx: ?*anyopaque) void = null,

    /// Release the owned database resources.
    ///
    /// Safe to call even if no deinit callback was set (e.g., for unmanaged databases).
    /// After calling deinit, the `db` handle is invalid and must not be used.
    pub fn deinit(self: OwnedDatabase) void {
        if (self.deinit_fn) |f| {
            f(self.deinit_ctx);
        }
    }

    /// Create a non-owned wrapper (for databases not created by a factory).
    ///
    /// The returned `OwnedDatabase` has no cleanup callback. This is useful
    /// when a `Database` handle is obtained from a long-lived backend that
    /// manages its own lifetime.
    pub fn unmanaged(db: Database) OwnedDatabase {
        return .{ .db = db };
    }
};

/// A single write operation for use with `Database.VTable.write_batch`.
///
/// Each operation represents either a key-value insertion or a key deletion.
/// Operations are accumulated in a `WriteBatch` and applied together via
/// `WriteBatch.commit()`.
pub const WriteBatchOp = union(enum) {
    /// Store a key-value pair. Overwrites any existing value for the key.
    put: struct {
        /// The key to store. Owned by the `WriteBatch` arena.
        key: []const u8,
        /// The value to associate with the key. Owned by the `WriteBatch` arena.
        value: []const u8,
    },
    /// Remove the entry for a key. No-op if the key does not exist.
    del: struct {
        /// The key to remove. Owned by the `WriteBatch` arena.
        key: []const u8,
    },
    /// Apply a merge operation (RocksDB native merge operator).
    ///
    /// Merge operations enable efficient read-modify-write patterns without
    /// requiring a read-before-write round-trip. The merge operator (configured
    /// at the backend level) defines how the value is combined with any
    /// existing value for the key.
    ///
    /// Mirrors Nethermind's `IMergeableKeyValueStore.Merge(key, value, flags)`.
    merge: struct {
        /// The key to merge into. Owned by the `WriteBatch` arena.
        key: []const u8,
        /// The merge operand value. Owned by the `WriteBatch` arena.
        value: []const u8,
        /// Write flags for this merge operation (e.g., low_priority, disable_wal).
        flags: WriteFlags = WriteFlags.none,
    },
};

/// Batch context for accumulating multiple write operations and applying
/// them atomically to a `Database`.
///
/// Modeled after Nethermind's `IWriteBatch` / `RocksDbWriteBatch`:
///   - `put()` / `delete()` accumulate operations without touching the DB.
///   - `commit()` applies all pending operations to the target database.
///   - `clear()` discards all pending operations and frees arena memory.
///   - `deinit()` releases all memory (must be called even after commit).
///
/// ## Atomicity
///
/// If the target database implements `VTable.write_batch`, commit uses it
/// for true all-or-nothing semantics. Otherwise, operations are applied
/// sequentially; on error, already-applied operations are NOT rolled back
/// and the batch is NOT cleared (caller can inspect/retry).
///
/// ## Usage
///
/// ```zig
/// var batch = WriteBatch.init(allocator, db);
/// defer batch.deinit();
///
/// try batch.put("key1", "value1");
/// try batch.put("key2", "value2");
/// try batch.delete("key3");
/// try batch.commit(); // atomic apply (if backend supports it)
/// ```
pub const WriteBatch = struct {
    /// Pending operations, in order of insertion.
    ops: std.ArrayListUnmanaged(WriteBatchOp) = .{},
    /// Allocator used for the ops list to avoid arena reallocation bloat.
    ops_allocator: std.mem.Allocator,
    /// Arena for owned copies of keys/values within this batch.
    arena: std.heap.ArenaAllocator,
    /// The target database to apply operations to on `commit()`.
    target: Database,

    /// Create a new empty WriteBatch targeting the given database.
    pub fn init(backing_allocator: std.mem.Allocator, target: Database) WriteBatch {
        return .{
            .ops_allocator = backing_allocator,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .target = target,
        };
    }

    /// Release all memory owned by this batch (pending ops, copied keys/values).
    pub fn deinit(self: *WriteBatch) void {
        self.ops.deinit(self.ops_allocator);
        self.arena.deinit();
    }

    /// Queue a put operation. Both key and value are copied into the batch arena.
    pub fn put(self: *WriteBatch, key: []const u8, value: []const u8) Error!void {
        const alloc = self.arena.allocator();
        const owned_key = alloc.dupe(u8, key) catch return error.OutOfMemory;
        const owned_val = alloc.dupe(u8, value) catch return error.OutOfMemory;
        self.ops.append(self.ops_allocator, .{ .put = .{ .key = owned_key, .value = owned_val } }) catch return error.OutOfMemory;
    }

    /// Queue a delete operation. The key is copied into the batch arena.
    pub fn delete(self: *WriteBatch, key: []const u8) Error!void {
        const alloc = self.arena.allocator();
        const owned_key = alloc.dupe(u8, key) catch return error.OutOfMemory;
        self.ops.append(self.ops_allocator, .{ .del = .{ .key = owned_key } }) catch return error.OutOfMemory;
    }

    /// Queue a merge operation with default write flags.
    /// Both key and value are copied into the batch arena.
    ///
    /// The merge will be applied when `commit()` is called. If the target database
    /// does not support merge, `commit()` will return `error.UnsupportedOperation`
    /// when it reaches this operation (via the sequential fallback path) or the
    /// backend must handle `.merge` variants in its `write_batch` implementation.
    pub fn merge(self: *WriteBatch, key: []const u8, value: []const u8) Error!void {
        return self.merge_with_flags(key, value, WriteFlags.none);
    }

    /// Queue a merge operation with explicit write flags.
    /// Both key and value are copied into the batch arena.
    ///
    /// Mirrors Nethermind's `IWriteBatch` inheriting `IMergeableKeyValueStore`'s
    /// full `Merge(key, value, flags)` signature.
    pub fn merge_with_flags(self: *WriteBatch, key: []const u8, value: []const u8, flags: WriteFlags) Error!void {
        const alloc = self.arena.allocator();
        const owned_key = alloc.dupe(u8, key) catch return error.OutOfMemory;
        const owned_val = alloc.dupe(u8, value) catch return error.OutOfMemory;
        self.ops.append(self.ops_allocator, .{ .merge = .{ .key = owned_key, .value = owned_val, .flags = flags } }) catch return error.OutOfMemory;
    }

    /// Apply all pending operations to the target database.
    ///
    /// If the backend provides `write_batch`, all operations are applied
    /// atomically (all-or-nothing). Otherwise, operations are applied
    /// sequentially; on error, already-applied operations remain and the
    /// batch retains its pending ops for inspection or retry.
    ///
    /// On success, pending ops are cleared. `deinit()` must still be
    /// called to release arena memory back to the allocator.
    ///
    /// Input lifetimes: keys/values passed to the backend are owned by the
    /// batch arena and are only valid during `commit()`. Backends must copy
    /// if they need to retain them beyond the call.
    pub fn commit(self: *WriteBatch) Error!void {
        if (self.ops.items.len == 0) return;

        if (self.target.vtable.write_batch) |batch_fn| {
            // Atomic path: backend handles all-or-nothing semantics.
            try batch_fn(self.target.ptr, self.ops.items);
        } else {
            // Sequential fallback: apply one-by-one.
            // On error, ops are NOT cleared so caller can inspect/retry.
            for (self.ops.items) |op| {
                switch (op) {
                    .put => |p| try self.target.put(p.key, p.value),
                    .del => |d| try self.target.delete(d.key),
                    .merge => |m| try self.target.merge_with_flags(m.key, m.value, m.flags),
                }
            }
        }
        // Only clear on success (reset arena to avoid unbounded growth).
        self.clear();
    }

    /// Discard all pending operations without applying them.
    /// Resets the arena to free accumulated key/value memory, preventing
    /// unbounded memory retention for long-lived batches.
    pub fn clear(self: *WriteBatch) void {
        self.ops.items.len = 0;
        // Reset arena to free all accumulated key/value copies.
        // This prevents unbounded memory growth for long-lived batches
        // that repeatedly accumulate and clear operations.
        _ = self.arena.reset(.free_all);
    }

    /// Return the number of pending operations.
    pub fn pending(self: *const WriteBatch) usize {
        return self.ops.items.len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// No-op / stub implementations used as defaults in test vtables.
const test_stubs = struct {
    fn name_default(_: *anyopaque) DbName {
        return .metadata;
    }
    fn get_null(_: *anyopaque, _: []const u8, _: ReadFlags) Error!?DbValue {
        return null;
    }
    fn put_noop(_: *anyopaque, _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {}
    fn delete_noop(_: *anyopaque, _: []const u8, _: WriteFlags) Error!void {}
    fn contains_false(_: *anyopaque, _: []const u8) Error!bool {
        return false;
    }
    fn iterator_unsupported(_: *anyopaque, _: bool) Error!DbIterator {
        return error.UnsupportedOperation;
    }
    fn snapshot_unsupported(_: *anyopaque) Error!DbSnapshot {
        return error.UnsupportedOperation;
    }
    fn flush_noop(_: *anyopaque, _: bool) Error!void {}
    fn clear_noop(_: *anyopaque) Error!void {}
    fn compact_noop(_: *anyopaque) Error!void {}
    fn gather_metric_zero(_: *anyopaque) Error!DbMetric {
        return .{};
    }
};

/// Build a `Database.VTable` with sensible no-op/stub defaults for tests.
///
/// Callers override only the fields they care about, eliminating boilerplate
/// in test mocks. Example:
///
/// ```zig
/// const vtable = test_vtable(.{ .put = my_put_impl, .merge = my_merge_impl });
/// ```
fn test_vtable(overrides: struct {
    name: *const fn (*anyopaque) DbName = test_stubs.name_default,
    get: *const fn (*anyopaque, []const u8, ReadFlags) Error!?DbValue = test_stubs.get_null,
    put: *const fn (*anyopaque, []const u8, ?[]const u8, WriteFlags) Error!void = test_stubs.put_noop,
    delete: *const fn (*anyopaque, []const u8, WriteFlags) Error!void = test_stubs.delete_noop,
    contains: *const fn (*anyopaque, []const u8) Error!bool = test_stubs.contains_false,
    iterator: *const fn (*anyopaque, bool) Error!DbIterator = test_stubs.iterator_unsupported,
    snapshot: *const fn (*anyopaque) Error!DbSnapshot = test_stubs.snapshot_unsupported,
    flush: *const fn (*anyopaque, bool) Error!void = test_stubs.flush_noop,
    clear: *const fn (*anyopaque) Error!void = test_stubs.clear_noop,
    compact: *const fn (*anyopaque) Error!void = test_stubs.compact_noop,
    gather_metric: *const fn (*anyopaque) Error!DbMetric = test_stubs.gather_metric_zero,
    write_batch: ?*const fn (*anyopaque, []const WriteBatchOp) Error!void = null,
    merge: ?*const fn (*anyopaque, []const u8, []const u8, WriteFlags) Error!void = null,
    multi_get: ?*const fn (*anyopaque, []const []const u8, []?DbValue, ReadFlags) Error!void = null,
}) Database.VTable {
    return .{
        .name = overrides.name,
        .get = overrides.get,
        .put = overrides.put,
        .delete = overrides.delete,
        .contains = overrides.contains,
        .iterator = overrides.iterator,
        .snapshot = overrides.snapshot,
        .flush = overrides.flush,
        .clear = overrides.clear,
        .compact = overrides.compact,
        .gather_metric = overrides.gather_metric,
        .write_batch = overrides.write_batch,
        .merge = overrides.merge,
        .multi_get = overrides.multi_get,
    };
}

/// Minimal mock database for testing the vtable dispatch mechanism.
/// This is NOT the full MemoryDatabase (that goes in memory.zig).
const MockDb = struct {
    call_count: usize = 0,

    fn get_impl(ptr: *anyopaque, _: []const u8, _: ReadFlags) Error!?DbValue {
        const self: *MockDb = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        return null;
    }

    fn put_impl(ptr: *anyopaque, _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {
        const self: *MockDb = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
    }

    fn delete_impl(ptr: *anyopaque, _: []const u8, _: WriteFlags) Error!void {
        const self: *MockDb = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
    }

    fn contains_impl(ptr: *anyopaque, _: []const u8) Error!bool {
        const self: *MockDb = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        return false;
    }

    const vtable = test_vtable(.{
        .get = get_impl,
        .put = put_impl,
        .delete = delete_impl,
        .contains = contains_impl,
    });

    fn database(self: *MockDb) Database {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

test "Database vtable dispatches get" {
    var mock = MockDb{};
    const db = mock.database();

    const result = try db.get("test_key");
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "Database vtable dispatches put" {
    var mock = MockDb{};
    const db = mock.database();

    try db.put("key", "value");
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "Database vtable dispatches put with null (delete semantics)" {
    var mock = MockDb{};
    const db = mock.database();

    try db.put("key", null);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "Database vtable dispatches delete" {
    var mock = MockDb{};
    const db = mock.database();

    try db.delete("key");
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "Database vtable dispatches contains" {
    var mock = MockDb{};
    const db = mock.database();

    const result = try db.contains("key");
    try std.testing.expectEqual(false, result);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "Database supports_write_batch reports false when absent" {
    var mock = MockDb{};
    const db = mock.database();

    try std.testing.expect(!db.supports_write_batch());
}

test "Database supports_write_batch reports true when present" {
    const BatchDb = struct {
        fn write_batch_impl(_: *anyopaque, _: []const WriteBatchOp) Error!void {}

        const vtable = test_vtable(.{ .write_batch = write_batch_impl });

        fn database(self: *@This()) Database {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
    };

    var db_impl = BatchDb{};
    const db = db_impl.database();

    try std.testing.expect(db.supports_write_batch());
}

test "Database vtable dispatches multiple operations" {
    var mock = MockDb{};
    const db = mock.database();

    _ = try db.get("a");
    try db.put("b", "val");
    try db.delete("c");
    _ = try db.contains("d");

    try std.testing.expectEqual(@as(usize, 4), mock.call_count);
}

test "Database start_write_batch creates batch targeting database" {
    var tracker = TrackingDb.init(std.testing.allocator);
    defer tracker.deinit();

    const db = tracker.database();
    var batch = db.start_write_batch(std.testing.allocator);
    defer batch.deinit();

    try batch.put("key1", "val1");
    try batch.commit();

    try std.testing.expectEqual(@as(usize, 1), tracker.puts.items.len);
    try std.testing.expectEqualStrings("key1", tracker.puts.items[0].key);
    try std.testing.expectEqualStrings("val1", tracker.puts.items[0].value.?);
}

test "DbName to_string matches Nethermind constants" {
    try std.testing.expectEqualStrings("state", DbName.state.to_string());
    try std.testing.expectEqualStrings("storage", DbName.storage.to_string());
    try std.testing.expectEqualStrings("code", DbName.code.to_string());
    try std.testing.expectEqualStrings("blocks", DbName.blocks.to_string());
    try std.testing.expectEqualStrings("headers", DbName.headers.to_string());
    try std.testing.expectEqualStrings("blockNumbers", DbName.block_numbers.to_string());
    try std.testing.expectEqualStrings("receipts", DbName.receipts.to_string());
    try std.testing.expectEqualStrings("blockInfos", DbName.block_infos.to_string());
    try std.testing.expectEqualStrings("badBlocks", DbName.bad_blocks.to_string());
    try std.testing.expectEqualStrings("bloom", DbName.bloom.to_string());
    try std.testing.expectEqualStrings("metadata", DbName.metadata.to_string());
    try std.testing.expectEqualStrings("blobTransactions", DbName.blob_transactions.to_string());
    try std.testing.expectEqualStrings("discoveryNodes", DbName.discovery_nodes.to_string());
    try std.testing.expectEqualStrings("discoveryV5Nodes", DbName.discovery_v5_nodes.to_string());
    try std.testing.expectEqualStrings("peers", DbName.peers.to_string());
}

test "DbName enum has all expected variants" {
    // Verify we can iterate all variants (compile-time check).
    // 15 = 12 original + 3 networking (discovery_nodes, discovery_v5_nodes, peers)
    const fields = std.meta.fields(DbName);
    try std.testing.expectEqual(@as(usize, 15), fields.len);
}

// -- WriteBatch tests -------------------------------------------------------

/// A tracking mock database for WriteBatch tests.
/// Records every put/delete so we can verify commit behavior.
const TrackingDb = struct {
    puts: std.ArrayListUnmanaged(struct { key: []const u8, value: ?[]const u8 }) = .{},
    deletes: std.ArrayListUnmanaged([]const u8) = .{},
    alloc: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TrackingDb {
        return .{ .alloc = allocator };
    }

    fn deinit(self: *TrackingDb) void {
        for (self.puts.items) |entry| {
            self.alloc.free(entry.key);
            if (entry.value) |val| {
                self.alloc.free(val);
            }
        }
        for (self.deletes.items) |key| {
            self.alloc.free(key);
        }
        self.puts.deinit(self.alloc);
        self.deletes.deinit(self.alloc);
    }

    fn put_impl(ptr: *anyopaque, key: []const u8, value: ?[]const u8, _: WriteFlags) Error!void {
        const self: *TrackingDb = @ptrCast(@alignCast(ptr));
        const owned_key = self.alloc.dupe(u8, key) catch return error.OutOfMemory;
        var owned_value: ?[]const u8 = null;
        if (value) |val| {
            owned_value = self.alloc.dupe(u8, val) catch {
                self.alloc.free(owned_key);
                return error.OutOfMemory;
            };
        }
        self.puts.append(self.alloc, .{ .key = owned_key, .value = owned_value }) catch {
            self.alloc.free(owned_key);
            if (owned_value) |val| self.alloc.free(val);
            return error.OutOfMemory;
        };
    }

    fn delete_impl(ptr: *anyopaque, key: []const u8, _: WriteFlags) Error!void {
        const self: *TrackingDb = @ptrCast(@alignCast(ptr));
        const owned_key = self.alloc.dupe(u8, key) catch return error.OutOfMemory;
        self.deletes.append(self.alloc, owned_key) catch {
            self.alloc.free(owned_key);
            return error.OutOfMemory;
        };
    }

    const vtable = test_vtable(.{ .put = put_impl, .delete = delete_impl });

    fn database(self: *TrackingDb) Database {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

test "WriteBatch: commit applies put operations" {
    var tracker = TrackingDb.init(std.testing.allocator);
    defer tracker.deinit();

    var batch = WriteBatch.init(std.testing.allocator, tracker.database());
    defer batch.deinit();

    try batch.put("key1", "val1");
    try batch.put("key2", "val2");
    try std.testing.expectEqual(@as(usize, 2), batch.pending());

    try batch.commit();
    try std.testing.expectEqual(@as(usize, 0), batch.pending());
    try std.testing.expectEqual(@as(usize, 2), tracker.puts.items.len);
    try std.testing.expectEqualStrings("key1", tracker.puts.items[0].key);
    try std.testing.expectEqualStrings("val1", tracker.puts.items[0].value.?);
    try std.testing.expectEqualStrings("key2", tracker.puts.items[1].key);
    try std.testing.expectEqualStrings("val2", tracker.puts.items[1].value.?);
}

test "WriteBatch: commit applies delete operations" {
    var tracker = TrackingDb.init(std.testing.allocator);
    defer tracker.deinit();

    var batch = WriteBatch.init(std.testing.allocator, tracker.database());
    defer batch.deinit();

    try batch.delete("gone");
    try std.testing.expectEqual(@as(usize, 1), batch.pending());

    try batch.commit();
    try std.testing.expectEqual(@as(usize, 1), tracker.deletes.items.len);
    try std.testing.expectEqualStrings("gone", tracker.deletes.items[0]);
}

test "WriteBatch: commit applies mixed operations in order" {
    var tracker = TrackingDb.init(std.testing.allocator);
    defer tracker.deinit();

    var batch = WriteBatch.init(std.testing.allocator, tracker.database());
    defer batch.deinit();

    try batch.put("a", "1");
    try batch.delete("b");
    try batch.put("c", "3");
    try std.testing.expectEqual(@as(usize, 3), batch.pending());

    try batch.commit();
    // 2 puts, 1 delete
    try std.testing.expectEqual(@as(usize, 2), tracker.puts.items.len);
    try std.testing.expectEqual(@as(usize, 1), tracker.deletes.items.len);
}

test "WriteBatch: clear discards pending operations" {
    var tracker = TrackingDb.init(std.testing.allocator);
    defer tracker.deinit();

    var batch = WriteBatch.init(std.testing.allocator, tracker.database());
    defer batch.deinit();

    try batch.put("key", "value");
    try batch.delete("other");
    try std.testing.expectEqual(@as(usize, 2), batch.pending());

    batch.clear();
    try std.testing.expectEqual(@as(usize, 0), batch.pending());

    // Commit after clear should apply nothing
    try batch.commit();
    try std.testing.expectEqual(@as(usize, 0), tracker.puts.items.len);
    try std.testing.expectEqual(@as(usize, 0), tracker.deletes.items.len);
}

test "WriteBatch: empty batch commit is no-op" {
    var tracker = TrackingDb.init(std.testing.allocator);
    defer tracker.deinit();

    var batch = WriteBatch.init(std.testing.allocator, tracker.database());
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 0), batch.pending());
    try batch.commit();
    try std.testing.expectEqual(@as(usize, 0), tracker.puts.items.len);
    try std.testing.expectEqual(@as(usize, 0), tracker.deletes.items.len);
}

test "WriteBatch: deinit frees all memory (leak check)" {
    var tracker = TrackingDb.init(std.testing.allocator);
    defer tracker.deinit();

    var batch = WriteBatch.init(std.testing.allocator, tracker.database());

    try batch.put("key1", "longvalue1");
    try batch.put("key2", "longvalue2");
    try batch.delete("key3");

    // If deinit doesn't free properly, testing allocator will report a leak
    batch.deinit();
}

// -- Atomicity and error behavior tests ------------------------------------

/// A mock database that fails after N successful writes (for atomicity testing).
const FailingDb = struct {
    /// Number of writes to succeed before failing.
    succeed_count: usize,
    /// Tracks how many writes have been applied.
    applied: usize = 0,

    fn put_impl(ptr: *anyopaque, _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {
        const self: *FailingDb = @ptrCast(@alignCast(ptr));
        if (self.applied >= self.succeed_count) {
            return Error.StorageError;
        }
        self.applied += 1;
    }

    fn delete_impl(ptr: *anyopaque, _: []const u8, _: WriteFlags) Error!void {
        const self: *FailingDb = @ptrCast(@alignCast(ptr));
        if (self.applied >= self.succeed_count) {
            return Error.StorageError;
        }
        self.applied += 1;
    }

    const vtable = test_vtable(.{ .put = put_impl, .delete = delete_impl });

    fn database(self: *FailingDb) Database {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

test "WriteBatch: sequential fallback retains ops on error for retry" {
    // FailingDb will succeed for 1 write, then fail on the 2nd.
    var failing = FailingDb{ .succeed_count = 1 };

    var batch = WriteBatch.init(std.testing.allocator, failing.database());
    defer batch.deinit();

    try batch.put("key1", "val1");
    try batch.put("key2", "val2");
    try batch.put("key3", "val3");

    // Commit should fail (2nd op fails after 1st succeeds)
    try std.testing.expectError(Error.StorageError, batch.commit());

    // Ops should be RETAINED on failure (not cleared)
    try std.testing.expectEqual(@as(usize, 3), batch.pending());
    // The failing db applied 1 write before failing
    try std.testing.expectEqual(@as(usize, 1), failing.applied);
}

/// A mock database that supports atomic write_batch (all-or-nothing).
const AtomicDb = struct {
    /// Tracks how many ops were committed atomically.
    committed_count: usize = 0,
    /// When true, write_batch will fail (to test rollback).
    should_fail: bool = false,

    fn put_impl(ptr: *anyopaque, _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {
        const self: *AtomicDb = @ptrCast(@alignCast(ptr));
        self.committed_count += 1;
    }

    fn delete_impl(ptr: *anyopaque, _: []const u8, _: WriteFlags) Error!void {
        const self: *AtomicDb = @ptrCast(@alignCast(ptr));
        self.committed_count += 1;
    }

    fn write_batch_impl(ptr: *anyopaque, ops: []const WriteBatchOp) Error!void {
        const self: *AtomicDb = @ptrCast(@alignCast(ptr));
        if (self.should_fail) {
            return Error.StorageError;
        }
        // Atomic: apply all or none.
        self.committed_count += ops.len;
    }

    const vtable = test_vtable(.{
        .put = put_impl,
        .delete = delete_impl,
        .write_batch = write_batch_impl,
    });

    fn database(self: *AtomicDb) Database {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

test "WriteBatch: uses write_batch vtable for atomic commit" {
    var atomic = AtomicDb{};

    var batch = WriteBatch.init(std.testing.allocator, atomic.database());
    defer batch.deinit();

    try batch.put("key1", "val1");
    try batch.put("key2", "val2");
    try batch.delete("key3");

    try batch.commit();

    // All 3 ops committed atomically via write_batch
    try std.testing.expectEqual(@as(usize, 3), atomic.committed_count);
    try std.testing.expectEqual(@as(usize, 0), batch.pending());
}

test "WriteBatch: atomic commit retains ops on failure (no partial apply)" {
    var atomic = AtomicDb{ .should_fail = true };

    var batch = WriteBatch.init(std.testing.allocator, atomic.database());
    defer batch.deinit();

    try batch.put("key1", "val1");
    try batch.put("key2", "val2");

    try std.testing.expectError(Error.StorageError, batch.commit());

    // No ops committed (atomic rollback)
    try std.testing.expectEqual(@as(usize, 0), atomic.committed_count);
    // Ops retained for retry
    try std.testing.expectEqual(@as(usize, 2), batch.pending());
}

test "WriteBatch: clear resets arena memory (reusable after clear)" {
    var tracker = TrackingDb.init(std.testing.allocator);
    defer tracker.deinit();

    var batch = WriteBatch.init(std.testing.allocator, tracker.database());
    defer batch.deinit();

    // Add many ops, clear, then add more — should not leak
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try batch.put("key", "value_with_some_length_to_force_alloc");
    }
    try std.testing.expectEqual(@as(usize, 50), batch.pending());

    batch.clear();
    try std.testing.expectEqual(@as(usize, 0), batch.pending());

    // Batch is reusable after clear
    try batch.put("new_key", "new_value");
    try std.testing.expectEqual(@as(usize, 1), batch.pending());

    try batch.commit();
    try std.testing.expectEqual(@as(usize, 1), tracker.puts.items.len);
}

test "WriteBatch: put propagates OutOfMemory not StorageError" {
    // Use a failing allocator to trigger OOM in put/delete
    var batch = WriteBatch.init(std.testing.failing_allocator, Database{
        .ptr = undefined,
        .vtable = &MockDb.vtable,
    });
    defer batch.deinit();

    // First put should fail with OutOfMemory from the failing allocator
    try std.testing.expectError(error.OutOfMemory, batch.put("key", "value"));
}

test "WriteBatch: delete propagates OutOfMemory not StorageError" {
    var batch = WriteBatch.init(std.testing.failing_allocator, Database{
        .ptr = undefined,
        .vtable = &MockDb.vtable,
    });
    defer batch.deinit();

    try std.testing.expectError(error.OutOfMemory, batch.delete("key"));
}

// -- Database.init comptime helper tests ------------------------------------

test "Database.init generates correct vtable dispatch" {
    // Verify that Database.init correctly recovers the typed pointer and
    // dispatches through the comptime-generated wrapper functions.
    const TestBackend = struct {
        value: u64 = 0,

        fn name_impl(_: *@This()) DbName {
            return .state;
        }
        fn get_impl(self: *@This(), _: []const u8, _: ReadFlags) Error!?DbValue {
            self.value += 1;
            return null;
        }
        fn put_impl(self: *@This(), _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {
            self.value += 10;
        }
        fn delete_impl(self: *@This(), _: []const u8, _: WriteFlags) Error!void {
            self.value += 100;
        }
        fn contains_impl(_: *@This(), _: []const u8) Error!bool {
            return false;
        }
        fn iterator_impl(_: *@This(), _: bool) Error!DbIterator {
            return error.UnsupportedOperation;
        }
        fn snapshot_impl(_: *@This()) Error!DbSnapshot {
            return error.UnsupportedOperation;
        }
        fn flush_impl(_: *@This(), _: bool) Error!void {}
        fn clear_impl(_: *@This()) Error!void {}
        fn compact_impl(_: *@This()) Error!void {}
        fn gather_metric_impl(_: *@This()) Error!DbMetric {
            return .{};
        }
    };

    var backend = TestBackend{};
    const db = Database.init(TestBackend, &backend, .{
        .name = TestBackend.name_impl,
        .get = TestBackend.get_impl,
        .put = TestBackend.put_impl,
        .delete = TestBackend.delete_impl,
        .contains = TestBackend.contains_impl,
        .iterator = TestBackend.iterator_impl,
        .snapshot = TestBackend.snapshot_impl,
        .flush = TestBackend.flush_impl,
        .clear = TestBackend.clear_impl,
        .compact = TestBackend.compact_impl,
        .gather_metric = TestBackend.gather_metric_impl,
    });

    // Dispatch through vtable and verify typed self is recovered
    try std.testing.expectEqual(DbName.state, db.name());

    _ = try db.get("key");
    try std.testing.expectEqual(@as(u64, 1), backend.value);

    try db.put("key", "val");
    try std.testing.expectEqual(@as(u64, 11), backend.value);

    try db.delete("key");
    try std.testing.expectEqual(@as(u64, 111), backend.value);

    try std.testing.expectEqual(false, try db.contains("key"));
    try std.testing.expect(!db.supports_write_batch());
}

test "Database.init with write_batch" {
    const TestBatchBackend = struct {
        batch_count: usize = 0,

        fn name_impl(_: *@This()) DbName {
            return .code;
        }
        fn get_impl(_: *@This(), _: []const u8, _: ReadFlags) Error!?DbValue {
            return null;
        }
        fn put_impl(_: *@This(), _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {}
        fn delete_impl(_: *@This(), _: []const u8, _: WriteFlags) Error!void {}
        fn contains_impl(_: *@This(), _: []const u8) Error!bool {
            return false;
        }
        fn iterator_impl(_: *@This(), _: bool) Error!DbIterator {
            return error.UnsupportedOperation;
        }
        fn snapshot_impl(_: *@This()) Error!DbSnapshot {
            return error.UnsupportedOperation;
        }
        fn flush_impl(_: *@This(), _: bool) Error!void {}
        fn clear_impl(_: *@This()) Error!void {}
        fn compact_impl(_: *@This()) Error!void {}
        fn gather_metric_impl(_: *@This()) Error!DbMetric {
            return .{};
        }
        fn write_batch_impl(self: *@This(), ops: []const WriteBatchOp) Error!void {
            self.batch_count += ops.len;
        }
    };

    var backend = TestBatchBackend{};
    const db = Database.init(TestBatchBackend, &backend, .{
        .name = TestBatchBackend.name_impl,
        .get = TestBatchBackend.get_impl,
        .put = TestBatchBackend.put_impl,
        .delete = TestBatchBackend.delete_impl,
        .contains = TestBatchBackend.contains_impl,
        .iterator = TestBatchBackend.iterator_impl,
        .snapshot = TestBatchBackend.snapshot_impl,
        .flush = TestBatchBackend.flush_impl,
        .clear = TestBatchBackend.clear_impl,
        .compact = TestBatchBackend.compact_impl,
        .gather_metric = TestBatchBackend.gather_metric_impl,
        .write_batch = TestBatchBackend.write_batch_impl,
    });

    try std.testing.expect(db.supports_write_batch());

    // Dispatch through vtable
    var batch = db.start_write_batch(std.testing.allocator);
    defer batch.deinit();

    try batch.put("k1", "v1");
    try batch.put("k2", "v2");
    try batch.commit();

    try std.testing.expectEqual(@as(usize, 2), backend.batch_count);
}

test "Database.init without write_batch defaults to null" {
    const MinimalBackend = struct {
        fn name_impl(_: *@This()) DbName {
            return .metadata;
        }
        fn get_impl(_: *@This(), _: []const u8, _: ReadFlags) Error!?DbValue {
            return null;
        }
        fn put_impl(_: *@This(), _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {}
        fn delete_impl(_: *@This(), _: []const u8, _: WriteFlags) Error!void {}
        fn contains_impl(_: *@This(), _: []const u8) Error!bool {
            return false;
        }
        fn iterator_impl(_: *@This(), _: bool) Error!DbIterator {
            return error.UnsupportedOperation;
        }
        fn snapshot_impl(_: *@This()) Error!DbSnapshot {
            return error.UnsupportedOperation;
        }
        fn flush_impl(_: *@This(), _: bool) Error!void {}
        fn clear_impl(_: *@This()) Error!void {}
        fn compact_impl(_: *@This()) Error!void {}
        fn gather_metric_impl(_: *@This()) Error!DbMetric {
            return .{};
        }
    };

    var backend = MinimalBackend{};
    const db = Database.init(MinimalBackend, &backend, .{
        .name = MinimalBackend.name_impl,
        .get = MinimalBackend.get_impl,
        .put = MinimalBackend.put_impl,
        .delete = MinimalBackend.delete_impl,
        .contains = MinimalBackend.contains_impl,
        .iterator = MinimalBackend.iterator_impl,
        .snapshot = MinimalBackend.snapshot_impl,
        .flush = MinimalBackend.flush_impl,
        .clear = MinimalBackend.clear_impl,
        .compact = MinimalBackend.compact_impl,
        .gather_metric = MinimalBackend.gather_metric_impl,
        // write_batch deliberately omitted — should default to null
    });

    try std.testing.expect(!db.supports_write_batch());
    try std.testing.expectEqual(DbName.metadata, db.name());
}

// -- OwnedDatabase tests ---------------------------------------------------

test "OwnedDatabase: deinit calls cleanup function" {
    var called: bool = false;

    const owned = OwnedDatabase{
        .db = Database{ .ptr = undefined, .vtable = &MockDb.vtable },
        .deinit_ctx = @ptrCast(&called),
        .deinit_fn = struct {
            fn cleanup(ctx: ?*anyopaque) void {
                const flag: *bool = @ptrCast(@alignCast(ctx.?));
                flag.* = true;
            }
        }.cleanup,
    };

    owned.deinit();
    try std.testing.expect(called);
}

test "OwnedDatabase: deinit is safe with null deinit_fn" {
    const owned = OwnedDatabase{
        .db = Database{ .ptr = undefined, .vtable = &MockDb.vtable },
    };

    // Should not panic or crash
    owned.deinit();
}

test "OwnedDatabase: unmanaged wraps without cleanup" {
    var mock = MockDb{};
    const db = mock.database();

    const owned = OwnedDatabase.unmanaged(db);

    // Should have no cleanup callback
    try std.testing.expect(owned.deinit_fn == null);
    try std.testing.expect(owned.deinit_ctx == null);

    // The db handle should work normally
    const result = try owned.db.get("test_key");
    try std.testing.expect(result == null);

    // deinit should be safe (no-op)
    owned.deinit();
}

test "OwnedDatabase: deinit passes context to cleanup function" {
    const CtxTracker = struct {
        received_ctx: ?*anyopaque = null,
        sentinel_ptr: *u8,
    };

    var sentinel: u8 = 42;
    var tracker = CtxTracker{ .sentinel_ptr = &sentinel };

    const owned = OwnedDatabase{
        .db = Database{ .ptr = undefined, .vtable = &MockDb.vtable },
        .deinit_ctx = @ptrCast(&tracker),
        .deinit_fn = struct {
            fn cleanup(ctx: ?*anyopaque) void {
                const t: *CtxTracker = @ptrCast(@alignCast(ctx.?));
                t.received_ctx = @ptrCast(t.sentinel_ptr);
            }
        }.cleanup,
    };

    owned.deinit();
    try std.testing.expect(tracker.received_ctx != null);
    try std.testing.expectEqual(@intFromPtr(&sentinel), @intFromPtr(tracker.received_ctx.?));
}

// -- Merge operation tests --------------------------------------------------

test "Database supports_merge reports false when absent" {
    var mock = MockDb{};
    const db = mock.database();
    try std.testing.expect(!db.supports_merge());
}

test "Database supports_merge reports true when present" {
    const MergeDb = struct {
        fn merge_impl(_: *anyopaque, _: []const u8, _: []const u8, _: WriteFlags) Error!void {}
        const vtable = test_vtable(.{ .merge = merge_impl });
        fn database(self: *@This()) Database {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
    };

    var db_impl = MergeDb{};
    const db = db_impl.database();

    try std.testing.expect(db.supports_merge());
}

test "Database merge returns UnsupportedOperation when absent" {
    var mock = MockDb{};
    const db = mock.database();

    try std.testing.expectError(error.UnsupportedOperation, db.merge("key", "value"));
}

test "Database merge_with_flags returns UnsupportedOperation when absent" {
    var mock = MockDb{};
    const db = mock.database();

    try std.testing.expectError(error.UnsupportedOperation, db.merge_with_flags("key", "value", WriteFlags.disable_wal));
}

/// Reusable merge-tracking mock for merge vtable dispatch tests.
/// Tracks the last key, value, flags, and total merge count.
const MergeTracker = struct {
    last_key: ?[]const u8 = null,
    last_value: ?[]const u8 = null,
    last_flags: ?WriteFlags = null,
    merge_count: usize = 0,

    fn merge_impl(ptr: *anyopaque, key: []const u8, value: []const u8, flags: WriteFlags) Error!void {
        const self: *MergeTracker = @ptrCast(@alignCast(ptr));
        self.last_key = key;
        self.last_value = value;
        self.last_flags = flags;
        self.merge_count += 1;
    }

    const vtable = test_vtable(.{ .merge = merge_impl });

    fn database(self: *MergeTracker) Database {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

test "Database merge delegates to vtable" {
    var tracker = MergeTracker{};
    const db = tracker.database();

    try db.merge("mykey", "myvalue");

    try std.testing.expectEqual(@as(usize, 1), tracker.merge_count);
    try std.testing.expectEqualStrings("mykey", tracker.last_key.?);
    try std.testing.expectEqualStrings("myvalue", tracker.last_value.?);
    try std.testing.expectEqual(WriteFlags.none, tracker.last_flags.?);
}

test "Database merge_with_flags forwards flags" {
    var tracker = MergeTracker{};
    const db = tracker.database();

    try db.merge_with_flags("k", "v", WriteFlags.disable_wal);
    try std.testing.expectEqual(WriteFlags.disable_wal, tracker.last_flags.?);

    try db.merge_with_flags("k", "v", WriteFlags.low_priority_and_no_wal);
    try std.testing.expectEqual(WriteFlags.low_priority_and_no_wal, tracker.last_flags.?);
}

test "WriteBatchOp merge variant holds key, value, and flags" {
    const op = WriteBatchOp{ .merge = .{ .key = "hello", .value = "world" } };
    switch (op) {
        .merge => |m| {
            try std.testing.expectEqualStrings("hello", m.key);
            try std.testing.expectEqualStrings("world", m.value);
            try std.testing.expectEqual(WriteFlags.none, m.flags);
        },
        else => return error.UnsupportedOperation,
    }

    // With explicit flags
    const op2 = WriteBatchOp{ .merge = .{ .key = "k", .value = "v", .flags = WriteFlags.disable_wal } };
    try std.testing.expectEqual(WriteFlags.disable_wal, op2.merge.flags);
}

test "WriteBatch merge accumulates operations" {
    var mock = MockDb{};
    var batch = WriteBatch.init(std.testing.allocator, mock.database());
    defer batch.deinit();

    try batch.merge("key1", "val1");
    try std.testing.expectEqual(@as(usize, 1), batch.pending());

    try batch.merge("key2", "val2");
    try std.testing.expectEqual(@as(usize, 2), batch.pending());

    // Verify ops are merge type
    try std.testing.expectEqualStrings("key1", batch.ops.items[0].merge.key);
    try std.testing.expectEqualStrings("val1", batch.ops.items[0].merge.value);
    try std.testing.expectEqualStrings("key2", batch.ops.items[1].merge.key);
    try std.testing.expectEqualStrings("val2", batch.ops.items[1].merge.value);
}

/// Merge-tracking mock that owns copies of keys/values (for commit tests
/// where the WriteBatch arena is freed after commit succeeds).
const OwningMergeTracker = struct {
    merge_count: usize = 0,
    last_flags: ?WriteFlags = null,
    alloc: std.mem.Allocator,
    owned_keys: [8]?[]u8 = .{null} ** 8,
    owned_values: [8]?[]u8 = .{null} ** 8,

    fn merge_impl(ptr: *anyopaque, key: []const u8, value: []const u8, flags: WriteFlags) Error!void {
        const self: *OwningMergeTracker = @ptrCast(@alignCast(ptr));
        self.last_flags = flags;
        if (self.merge_count < 8) {
            self.owned_keys[self.merge_count] = self.alloc.dupe(u8, key) catch return error.OutOfMemory;
            self.owned_values[self.merge_count] = self.alloc.dupe(u8, value) catch return error.OutOfMemory;
        }
        self.merge_count += 1;
    }

    // No write_batch — forces sequential fallback path in WriteBatch.commit.
    const vtable = test_vtable(.{ .merge = merge_impl });

    fn database(self: *OwningMergeTracker) Database {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn deinit(self: *OwningMergeTracker) void {
        for (&self.owned_keys) |*k| {
            if (k.*) |key| self.alloc.free(key);
            k.* = null;
        }
        for (&self.owned_values) |*v| {
            if (v.*) |val| self.alloc.free(val);
            v.* = null;
        }
    }
};

test "WriteBatch commit applies merge ops via fallback path" {
    var merge_db = OwningMergeTracker{ .alloc = std.testing.allocator };
    defer merge_db.deinit();

    var batch = WriteBatch.init(std.testing.allocator, merge_db.database());
    defer batch.deinit();

    try batch.merge("mk1", "mv1");
    try batch.merge("mk2", "mv2");
    try batch.commit();

    try std.testing.expectEqual(@as(usize, 2), merge_db.merge_count);
    try std.testing.expectEqualStrings("mk1", merge_db.owned_keys[0].?);
    try std.testing.expectEqualStrings("mv1", merge_db.owned_values[0].?);
    try std.testing.expectEqualStrings("mk2", merge_db.owned_keys[1].?);
    try std.testing.expectEqualStrings("mv2", merge_db.owned_values[1].?);
    try std.testing.expectEqual(@as(usize, 0), batch.pending());
}

test "WriteBatch commit with merge ops via atomic path" {
    // AtomicDb already has write_batch — verify merge ops are included in the ops slice
    var atomic = AtomicDb{};

    var batch = WriteBatch.init(std.testing.allocator, atomic.database());
    defer batch.deinit();

    try batch.put("k1", "v1");
    try batch.merge("mk1", "mv1");
    try batch.delete("dk1");

    try batch.commit();

    // All 3 ops committed atomically via write_batch
    try std.testing.expectEqual(@as(usize, 3), atomic.committed_count);
    try std.testing.expectEqual(@as(usize, 0), batch.pending());
}

test "WriteBatch merge_with_flags forwards flags via fallback path" {
    // Reuses OwningMergeTracker which also tracks last_flags.
    var merge_db = OwningMergeTracker{ .alloc = std.testing.allocator };
    defer merge_db.deinit();

    var batch = WriteBatch.init(std.testing.allocator, merge_db.database());
    defer batch.deinit();

    try batch.merge_with_flags("k", "v", WriteFlags.low_priority_and_no_wal);
    try batch.commit();

    try std.testing.expectEqual(WriteFlags.low_priority_and_no_wal, merge_db.last_flags.?);
}

test "WriteBatch merge propagates OutOfMemory" {
    var batch = WriteBatch.init(std.testing.failing_allocator, Database{
        .ptr = undefined,
        .vtable = &MockDb.vtable,
    });
    defer batch.deinit();

    try std.testing.expectError(error.OutOfMemory, batch.merge("key", "value"));
}

test "Database.init with merge generates correct dispatch" {
    const MergeBackend = struct {
        merge_count: usize = 0,
        last_key: ?[]const u8 = null,
        last_value: ?[]const u8 = null,
        last_flags: ?WriteFlags = null,

        fn name_impl(_: *@This()) DbName {
            return .state;
        }
        fn get_impl(_: *@This(), _: []const u8, _: ReadFlags) Error!?DbValue {
            return null;
        }
        fn put_impl(_: *@This(), _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {}
        fn delete_impl(_: *@This(), _: []const u8, _: WriteFlags) Error!void {}
        fn contains_impl(_: *@This(), _: []const u8) Error!bool {
            return false;
        }
        fn iterator_impl(_: *@This(), _: bool) Error!DbIterator {
            return error.UnsupportedOperation;
        }
        fn snapshot_impl(_: *@This()) Error!DbSnapshot {
            return error.UnsupportedOperation;
        }
        fn flush_impl(_: *@This(), _: bool) Error!void {}
        fn clear_impl(_: *@This()) Error!void {}
        fn compact_impl(_: *@This()) Error!void {}
        fn gather_metric_impl(_: *@This()) Error!DbMetric {
            return .{};
        }
        fn merge_impl(self: *@This(), key: []const u8, value: []const u8, flags: WriteFlags) Error!void {
            self.merge_count += 1;
            self.last_key = key;
            self.last_value = value;
            self.last_flags = flags;
        }
    };

    var backend = MergeBackend{};
    const db = Database.init(MergeBackend, &backend, .{
        .name = MergeBackend.name_impl,
        .get = MergeBackend.get_impl,
        .put = MergeBackend.put_impl,
        .delete = MergeBackend.delete_impl,
        .contains = MergeBackend.contains_impl,
        .iterator = MergeBackend.iterator_impl,
        .snapshot = MergeBackend.snapshot_impl,
        .flush = MergeBackend.flush_impl,
        .clear = MergeBackend.clear_impl,
        .compact = MergeBackend.compact_impl,
        .gather_metric = MergeBackend.gather_metric_impl,
        .merge = MergeBackend.merge_impl,
    });

    try std.testing.expect(db.supports_merge());

    try db.merge("testkey", "testval");
    try std.testing.expectEqual(@as(usize, 1), backend.merge_count);
    try std.testing.expectEqualStrings("testkey", backend.last_key.?);
    try std.testing.expectEqualStrings("testval", backend.last_value.?);
    try std.testing.expectEqual(WriteFlags.none, backend.last_flags.?);

    try db.merge_with_flags("k2", "v2", WriteFlags.low_priority);
    try std.testing.expectEqual(@as(usize, 2), backend.merge_count);
    try std.testing.expectEqual(WriteFlags.low_priority, backend.last_flags.?);
}

test "Database.init without merge defaults to null" {
    const MinimalBackend2 = struct {
        fn name_impl(_: *@This()) DbName {
            return .metadata;
        }
        fn get_impl(_: *@This(), _: []const u8, _: ReadFlags) Error!?DbValue {
            return null;
        }
        fn put_impl(_: *@This(), _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {}
        fn delete_impl(_: *@This(), _: []const u8, _: WriteFlags) Error!void {}
        fn contains_impl(_: *@This(), _: []const u8) Error!bool {
            return false;
        }
        fn iterator_impl(_: *@This(), _: bool) Error!DbIterator {
            return error.UnsupportedOperation;
        }
        fn snapshot_impl(_: *@This()) Error!DbSnapshot {
            return error.UnsupportedOperation;
        }
        fn flush_impl(_: *@This(), _: bool) Error!void {}
        fn clear_impl(_: *@This()) Error!void {}
        fn compact_impl(_: *@This()) Error!void {}
        fn gather_metric_impl(_: *@This()) Error!DbMetric {
            return .{};
        }
    };

    var backend = MinimalBackend2{};
    const db = Database.init(MinimalBackend2, &backend, .{
        .name = MinimalBackend2.name_impl,
        .get = MinimalBackend2.get_impl,
        .put = MinimalBackend2.put_impl,
        .delete = MinimalBackend2.delete_impl,
        .contains = MinimalBackend2.contains_impl,
        .iterator = MinimalBackend2.iterator_impl,
        .snapshot = MinimalBackend2.snapshot_impl,
        .flush = MinimalBackend2.flush_impl,
        .clear = MinimalBackend2.clear_impl,
        .compact = MinimalBackend2.compact_impl,
        .gather_metric = MinimalBackend2.gather_metric_impl,
        // merge deliberately omitted — should default to null
    });

    try std.testing.expect(!db.supports_merge());
    try std.testing.expectError(error.UnsupportedOperation, db.merge("k", "v"));
}

// -- multi_get tests ---------------------------------------------------------

test "Database supports_multi_get reports false when absent" {
    var mock = MockDb{};
    const db = mock.database();
    try std.testing.expect(!db.supports_multi_get());
}

test "Database supports_multi_get reports true when present" {
    const MultiGetDb = struct {
        fn multi_get_impl(_: *anyopaque, _: []const []const u8, results: []?DbValue, _: ReadFlags) Error!void {
            for (results) |*r| r.* = null;
        }
        const vtable = test_vtable(.{ .multi_get = multi_get_impl });
        fn database(self: *@This()) Database {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
    };

    var db_impl = MultiGetDb{};
    const db = db_impl.database();
    try std.testing.expect(db.supports_multi_get());
}

test "Database multi_get sequential fallback returns correct results" {
    // Use a mock that returns known values for specific keys.
    const LookupDb = struct {
        fn get_impl(_: *anyopaque, key: []const u8, _: ReadFlags) Error!?DbValue {
            if (std.mem.eql(u8, key, "a")) return DbValue.borrowed("val_a");
            if (std.mem.eql(u8, key, "c")) return DbValue.borrowed("val_c");
            return null;
        }
        const vtable = test_vtable(.{ .get = get_impl });
        fn database(self: *@This()) Database {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
    };

    var lookup = LookupDb{};
    const db = lookup.database();

    const keys = &[_][]const u8{ "a", "b", "c" };
    var results: [3]?DbValue = undefined;
    try db.multi_get(keys, &results);

    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("val_a", results[0].?.bytes);
    try std.testing.expect(results[1] == null);
    try std.testing.expect(results[2] != null);
    try std.testing.expectEqualStrings("val_c", results[2].?.bytes);
}

test "Database multi_get_with_flags sequential fallback works" {
    // Verify flags are forwarded to get_with_flags.
    const FlagsDb = struct {
        received_flags: ?ReadFlags = null,

        fn get_impl(ptr: *anyopaque, _: []const u8, flags: ReadFlags) Error!?DbValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.received_flags = flags;
            return null;
        }
        const vtable = test_vtable(.{ .get = get_impl });
        fn database(self: *@This()) Database {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
    };

    var fdb = FlagsDb{};
    const db = fdb.database();

    const keys = &[_][]const u8{"key1"};
    var results: [1]?DbValue = undefined;
    try db.multi_get_with_flags(keys, &results, ReadFlags.hint_cache_miss);

    try std.testing.expectEqual(ReadFlags.hint_cache_miss, fdb.received_flags.?);
}

test "Database multi_get dispatches to vtable when present" {
    const DispatchDb = struct {
        dispatched: bool = false,

        fn multi_get_impl(ptr: *anyopaque, _: []const []const u8, results: []?DbValue, _: ReadFlags) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.dispatched = true;
            for (results) |*r| r.* = DbValue.borrowed("from_vtable");
        }
        const vtable = test_vtable(.{ .multi_get = multi_get_impl });
        fn database(self: *@This()) Database {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
    };

    var ddb = DispatchDb{};
    const db = ddb.database();

    const keys = &[_][]const u8{"key"};
    var results: [1]?DbValue = undefined;
    try db.multi_get(keys, &results);

    try std.testing.expect(ddb.dispatched);
    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("from_vtable", results[0].?.bytes);
}

test "Database multi_get with empty keys slice is no-op" {
    var mock = MockDb{};
    const db = mock.database();

    const keys: []const []const u8 = &.{};
    var results: [0]?DbValue = .{};
    try db.multi_get(keys, &results);

    // No calls made, no errors.
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);
}

test "Database.init with multi_get generates correct dispatch" {
    const MultiGetBackend = struct {
        call_count: usize = 0,

        fn name_impl(_: *@This()) DbName {
            return .state;
        }
        fn get_impl(_: *@This(), _: []const u8, _: ReadFlags) Error!?DbValue {
            return null;
        }
        fn put_impl(_: *@This(), _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {}
        fn delete_impl(_: *@This(), _: []const u8, _: WriteFlags) Error!void {}
        fn contains_impl(_: *@This(), _: []const u8) Error!bool {
            return false;
        }
        fn iterator_impl(_: *@This(), _: bool) Error!DbIterator {
            return error.UnsupportedOperation;
        }
        fn snapshot_impl(_: *@This()) Error!DbSnapshot {
            return error.UnsupportedOperation;
        }
        fn flush_impl(_: *@This(), _: bool) Error!void {}
        fn clear_impl(_: *@This()) Error!void {}
        fn compact_impl(_: *@This()) Error!void {}
        fn gather_metric_impl(_: *@This()) Error!DbMetric {
            return .{};
        }
        fn multi_get_impl(self: *@This(), _: []const []const u8, results: []?DbValue, _: ReadFlags) Error!void {
            self.call_count += 1;
            for (results) |*r| r.* = DbValue.borrowed("comptime_dispatch");
        }
    };

    var backend = MultiGetBackend{};
    const db = Database.init(MultiGetBackend, &backend, .{
        .name = MultiGetBackend.name_impl,
        .get = MultiGetBackend.get_impl,
        .put = MultiGetBackend.put_impl,
        .delete = MultiGetBackend.delete_impl,
        .contains = MultiGetBackend.contains_impl,
        .iterator = MultiGetBackend.iterator_impl,
        .snapshot = MultiGetBackend.snapshot_impl,
        .flush = MultiGetBackend.flush_impl,
        .clear = MultiGetBackend.clear_impl,
        .compact = MultiGetBackend.compact_impl,
        .gather_metric = MultiGetBackend.gather_metric_impl,
        .multi_get = MultiGetBackend.multi_get_impl,
    });

    try std.testing.expect(db.supports_multi_get());

    const keys = &[_][]const u8{ "k1", "k2" };
    var results: [2]?DbValue = undefined;
    try db.multi_get(keys, &results);

    try std.testing.expectEqual(@as(usize, 1), backend.call_count);
    try std.testing.expect(results[0] != null);
    try std.testing.expectEqualStrings("comptime_dispatch", results[0].?.bytes);
    try std.testing.expect(results[1] != null);
    try std.testing.expectEqualStrings("comptime_dispatch", results[1].?.bytes);
}

test "Database.init without multi_get defaults to null" {
    const MinimalBackend3 = struct {
        fn name_impl(_: *@This()) DbName {
            return .metadata;
        }
        fn get_impl(_: *@This(), _: []const u8, _: ReadFlags) Error!?DbValue {
            return null;
        }
        fn put_impl(_: *@This(), _: []const u8, _: ?[]const u8, _: WriteFlags) Error!void {}
        fn delete_impl(_: *@This(), _: []const u8, _: WriteFlags) Error!void {}
        fn contains_impl(_: *@This(), _: []const u8) Error!bool {
            return false;
        }
        fn iterator_impl(_: *@This(), _: bool) Error!DbIterator {
            return error.UnsupportedOperation;
        }
        fn snapshot_impl(_: *@This()) Error!DbSnapshot {
            return error.UnsupportedOperation;
        }
        fn flush_impl(_: *@This(), _: bool) Error!void {}
        fn clear_impl(_: *@This()) Error!void {}
        fn compact_impl(_: *@This()) Error!void {}
        fn gather_metric_impl(_: *@This()) Error!DbMetric {
            return .{};
        }
    };

    var backend = MinimalBackend3{};
    const db = Database.init(MinimalBackend3, &backend, .{
        .name = MinimalBackend3.name_impl,
        .get = MinimalBackend3.get_impl,
        .put = MinimalBackend3.put_impl,
        .delete = MinimalBackend3.delete_impl,
        .contains = MinimalBackend3.contains_impl,
        .iterator = MinimalBackend3.iterator_impl,
        .snapshot = MinimalBackend3.snapshot_impl,
        .flush = MinimalBackend3.flush_impl,
        .clear = MinimalBackend3.clear_impl,
        .compact = MinimalBackend3.compact_impl,
        .gather_metric = MinimalBackend3.gather_metric_impl,
        // multi_get deliberately omitted — should default to null
    });

    try std.testing.expect(!db.supports_multi_get());
}
