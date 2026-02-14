# Research Context: add-database-comptime-init

## Ticket Summary

Add a `Database.init(comptime T, ptr, comptime config)` helper to the Database struct
in `client/db/adapter.zig`, following the pattern already established by `DbIterator.init`
and `DbSnapshot.init`. This eliminates repeated `@ptrCast`/`@alignCast` boilerplate
across all four Database backends (MemoryDatabase, NullDb, ReadOnlyDb, RocksDatabase).

## Category

`phase-0-db` — DB Abstraction Layer

## PRD Reference

- `prd/GUILLOTINE_CLIENT_PLAN.md` — Phase 0: DB Abstraction Layer
- `prd/ETHEREUM_SPECS_REFERENCE.md` — Phase 0: N/A (internal abstraction, no Ethereum spec dependency)

## Existing Comptime Init Patterns (Reference)

### DbIterator.init (adapter.zig:216-243)

```zig
pub fn init(
    comptime T: type,
    ptr: *T,
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
    return .{ .ptr = @ptrCast(ptr), .vtable = &Wrapper.vtable };
}
```

### DbSnapshot.init (adapter.zig:277-319)

Same pattern with 4 function pointers: `get_fn`, `contains_fn`, `iterator_fn` (optional), `deinit_fn`.

### HostInterface (guillotine-mini/src/host.zig)

The HostInterface does NOT have a comptime init helper — it uses manual vtable
construction, similar to the current Database pattern. This is a secondary candidate
for the same refactor.

## Current Boilerplate Problem

Each backend manually constructs `Database.VTable` with `*anyopaque` function
signatures and repeats the same `@ptrCast(@alignCast(ptr))` cast in every
implementation function. The Database.VTable has 11 mandatory function pointers
plus 1 optional (`write_batch`).

### Files with duplicated boilerplate:

1. **`client/db/memory.zig`** (MemoryDatabase) — Lines 310-376
   - 11 vtable wrapper functions, each containing `@ptrCast(@alignCast(ptr))`
   - VTable struct at line 310

2. **`client/db/null.zig`** (NullDb) — Lines 61-157
   - 11 vtable wrapper functions
   - Some don't use `ptr` at all (returns constants)
   - VTable struct at line 61

3. **`client/db/rocksdb.zig`** (RocksDatabase) — Lines 123-185
   - 11 vtable wrapper functions (all return `error.StorageError`)
   - VTable struct at line 123

4. **`client/db/read_only.zig`** (ReadOnlyDb) — Lines 297-395
   - 11 vtable wrapper functions
   - VTable struct at line 297

5. **`client/db/adapter.zig`** (test MockDb, TrackingDb, FailingDb, AtomicDb) — Lines 665-1139
   - 4 different test mock backends, each manually building vtables
   - MockDb, TrackingDb, FailingDb, AtomicDb all have their own manual vtables

### Total: ~55 manual `@ptrCast(@alignCast())` casts across all backends

## Database.VTable Signature (11 + 1 optional functions)

```zig
pub const VTable = struct {
    name:         *const fn (ptr: *anyopaque) DbName,
    get:          *const fn (ptr: *anyopaque, key: []const u8, flags: ReadFlags) Error!?DbValue,
    put:          *const fn (ptr: *anyopaque, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void,
    delete:       *const fn (ptr: *anyopaque, key: []const u8, flags: WriteFlags) Error!void,
    contains:     *const fn (ptr: *anyopaque, key: []const u8) Error!bool,
    iterator:     *const fn (ptr: *anyopaque, ordered: bool) Error!DbIterator,
    snapshot:     *const fn (ptr: *anyopaque) Error!DbSnapshot,
    flush:        *const fn (ptr: *anyopaque, only_wal: bool) Error!void,
    clear:        *const fn (ptr: *anyopaque) Error!void,
    compact:      *const fn (ptr: *anyopaque) Error!void,
    gather_metric:*const fn (ptr: *anyopaque) Error!DbMetric,
    write_batch:  ?*const fn (ptr: *anyopaque, ops: []const WriteBatchOp) Error!void = null,
};
```

## Proposed API Design

The init helper should accept comptime function pointers typed to the concrete type `T`,
generate wrapper functions that do the `@ptrCast/@alignCast`, and construct the vtable
at comptime. Key design decisions:

1. **All 11 functions as a config struct** (not 11 separate parameters) for readability
2. **`write_batch` is optional** (`?*const fn`) — defaults to `null`
3. **Functions that don't use `ptr`** (e.g., NullDb's `get` always returns null) should
   still work — the wrapper generates the cast but the implementation can ignore `self`

### Proposed signature:

```zig
pub fn init(comptime T: type, ptr: *T, comptime fns: struct {
    name:          *const fn (self: *T) DbName,
    get:           *const fn (self: *T, key: []const u8, flags: ReadFlags) Error!?DbValue,
    put:           *const fn (self: *T, key: []const u8, value: ?[]const u8, flags: WriteFlags) Error!void,
    delete:        *const fn (self: *T, key: []const u8, flags: WriteFlags) Error!void,
    contains:      *const fn (self: *T, key: []const u8) Error!bool,
    iterator:      *const fn (self: *T, ordered: bool) Error!DbIterator,
    snapshot:      *const fn (self: *T) Error!DbSnapshot,
    flush:         *const fn (self: *T, only_wal: bool) Error!void,
    clear:         *const fn (self: *T) Error!void,
    compact:       *const fn (self: *T) Error!void,
    gather_metric: *const fn (self: *T) Error!DbMetric,
    write_batch:   ?*const fn (self: *T, ops: []const WriteBatchOp) Error!void = null,
}) Database
```

## Nethermind Reference

### Interface Hierarchy
- `IDb` extends `IKeyValueStoreWithBatching + IDbMeta + IDisposable`
- `IKeyValueStore` extends `IReadOnlyKeyValueStore + IWriteOnlyKeyValueStore`
- Constructor patterns use C# DI (constructor injection), not vtable

### Key Files
- `nethermind/src/Nethermind/Nethermind.Db/IDb.cs` — Main interface
- `nethermind/src/Nethermind/Nethermind.Core/IKeyValueStore.cs` — Core KV interface hierarchy
- `nethermind/src/Nethermind/Nethermind.Db/NullDb.cs` — Null object (singleton pattern)
- `nethermind/src/Nethermind/Nethermind.Db/MemDb.cs` — In-memory (ConcurrentDictionary)
- `nethermind/src/Nethermind/Nethermind.Db/ReadOnlyDb.cs` — Read-only wrapper with optional overlay
- `nethermind/src/Nethermind/Nethermind.Db.Rocks/DbOnTheRocks.cs` — RocksDB backend

### Nethermind Pattern Note
Nethermind uses C# interfaces (IDb, IKeyValueStore) — not vtables. The Zig codebase
correctly translates this to a type-erased vtable pattern (ptr + VTable). The comptime
init helper is a Zig-specific ergonomic improvement that has no direct Nethermind equivalent.

## Voltaire Reference

### No Database primitives in Voltaire
Voltaire does NOT provide a raw key-value persistence interface. It provides:
- `StateManager` — typed state operations (balances, nonces, code, storage)
- `JournaledState` — dual-cache orchestrator with checkpoint/revert
- `StateCache` (AccountCache, StorageCache, ContractCache) — in-memory typed caches
- `ForkBackend` — async RPC-based state fetcher with LRU cache

The Database adapter fills the gap below Voltaire's state management layer:
`Voltaire StateManager → (typed state ops) → DB adapter → (raw KV) → backend`

### Voltaire APIs Referenced
- `voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig`
- `voltaire/packages/voltaire-zig/src/state-manager/JournaledState.zig`
- `voltaire/packages/voltaire-zig/src/state-manager/StateCache.zig`
- `voltaire/packages/voltaire-zig/src/evm/host.zig` — HostInterface vtable (same pattern, also lacks comptime init)

### Voltaire Comptime Patterns
Voltaire uses standard `.init()` constructors, NOT comptime vtable generation.
The comptime vtable init pattern is specific to the DB adapter layer.

## Test Fixtures

N/A — Phase 0 is an internal abstraction. No Ethereum test fixtures apply.
Testing is via unit tests in each backend file.

## Execution Specs

N/A — No Ethereum execution spec is relevant to this internal refactor.

## Implementation Checklist

1. Add `Database.init(comptime T, ptr, comptime fns)` to `client/db/adapter.zig`
2. Refactor `MemoryDatabase.database()` in `client/db/memory.zig` to use it
3. Refactor `NullDb.database()` in `client/db/null.zig` to use it
4. Refactor `RocksDatabase.database()` in `client/db/rocksdb.zig` to use it
5. Refactor `ReadOnlyDb.database()` in `client/db/read_only.zig` to use it
6. Refactor test mocks in `client/db/adapter.zig` (MockDb, TrackingDb, FailingDb, AtomicDb)
7. Remove now-dead manual vtable wrapper functions from each backend
8. Ensure all existing tests pass unchanged
9. Add dedicated tests for `Database.init` in `client/db/adapter.zig`

## Files to Modify

| File | Change |
|------|--------|
| `client/db/adapter.zig` | Add `Database.init` comptime helper + tests |
| `client/db/memory.zig` | Replace manual vtable with `Database.init` |
| `client/db/null.zig` | Replace manual vtable with `Database.init` |
| `client/db/rocksdb.zig` | Replace manual vtable with `Database.init` |
| `client/db/read_only.zig` | Replace manual vtable with `Database.init` |

## Risk Assessment

- **Low risk** — Pure refactor, no behavioral changes
- All existing tests serve as regression tests
- The pattern is already proven by `DbIterator.init` and `DbSnapshot.init`
- No Ethereum spec compliance impact
