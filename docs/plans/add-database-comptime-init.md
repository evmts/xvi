# Plan: Add comptime Database.init helper to reduce vtable boilerplate

## Overview

Add a `Database.init(comptime T, ptr, comptime fns)` helper to `client/db/adapter.zig` that generates type-safe vtable wrappers at comptime, following the proven pattern from `DbIterator.init` (line 216) and `DbSnapshot.init` (line 277). This eliminates ~55 manual `@ptrCast/@alignCast` casts across 4 production backends and 4 test mocks.

## Design Decisions

### Config struct vs positional parameters

`DbIterator.init` uses positional parameters (2 functions), `DbSnapshot.init` uses positional parameters (4 functions). With 12 function pointers, positional parameters would be unreadable. Use an **anonymous struct** for the config parameter.

### Optional `write_batch`

`write_batch` defaults to `null` in `Database.VTable`. The comptime config struct mirrors this with `write_batch: ?*const fn (self: *T, ops: []const WriteBatchOp) Error!void = null`. When `null`, the generated vtable sets `.write_batch = null`.

### Functions that ignore `self`

NullDb and RocksDatabase have vtable functions that discard `ptr` (e.g., `get_impl(_: *anyopaque, ...) -> null`). With the comptime helper, these functions receive `*T` instead of `*anyopaque` and can simply discard `self: *T` with `_`. The wrapper still performs the cast, but this is zero-cost (comptime-generated, inlined).

### Handling non-delegating vtable impls

Some backends (ReadOnlyDb, NullDb) have complex vtable implementations that don't simply delegate to a `self.method()` call — they contain branching logic, allocator access, etc. The comptime helper works fine for these because the `*const fn(self: *T, ...)` signature allows any implementation body.

## Step-by-step Implementation

### Step 1: Add `Database.init` comptime helper to `adapter.zig`

**File:** `client/db/adapter.zig` — inside the `Database` struct (after the `VTable` definition, before `pub fn name`)

**Signature:**
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

**Implementation pattern** (follows `DbIterator.init` exactly):
```zig
const Wrapper = struct {
    fn name_impl(raw: *anyopaque) DbName {
        const typed: *T = @ptrCast(@alignCast(raw));
        return fns.name(typed);
    }
    // ... (one wrapper per vtable function)
    fn write_batch_impl(raw: *anyopaque, ops: []const WriteBatchOp) Error!void {
        const typed: *T = @ptrCast(@alignCast(raw));
        const wb_fn = fns.write_batch orelse unreachable;
        return wb_fn(typed, ops);
    }
    const vtable = VTable{
        .name = name_impl,
        .get = get_impl,
        // ...
        .write_batch = if (fns.write_batch == null) null else write_batch_impl,
    };
};
return .{ .ptr = @ptrCast(ptr), .vtable = &Wrapper.vtable };
```

**Verify:** `zig fmt client/db/adapter.zig && zig build`

### Step 2: Add unit tests for `Database.init` in `adapter.zig`

**File:** `client/db/adapter.zig` — in the test section at the bottom

Add tests:

1. **"Database.init generates correct vtable dispatch"** — Create a minimal struct with typed methods, use `Database.init`, verify dispatch works and `self` pointer is recovered correctly (check mutation of a field through the vtable).

2. **"Database.init with write_batch"** — Create a struct with `write_batch` implemented, verify `supports_write_batch()` returns true and the function dispatches correctly.

3. **"Database.init without write_batch defaults to null"** — Create a struct without `write_batch`, verify `supports_write_batch()` returns false.

**Verify:** `zig build test -- --test-filter "Database.init"`

### Step 3: Refactor `MemoryDatabase` to use `Database.init`

**File:** `client/db/memory.zig`

**Changes:**
- Change vtable impl functions from `fn xxx_impl(ptr: *anyopaque, ...) -> ...` to `fn xxx_impl(self: *MemoryDatabase, ...) -> ...`
- Remove all `const self: *MemoryDatabase = @ptrCast(@alignCast(ptr));` lines
- Replace `const vtable = Database.VTable{ ... };` and `fn database(self: *MemoryDatabase) Database` with:
  ```zig
  pub fn database(self: *MemoryDatabase) Database {
      return Database.init(MemoryDatabase, self, .{
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
      });
  }
  ```
- Remove the old static `const vtable` declaration

**Verify:** `zig fmt client/db/memory.zig && zig build test` (all existing MemoryDatabase tests must pass unchanged)

### Step 4: Refactor `NullDb` to use `Database.init`

**File:** `client/db/null.zig`

**Changes:**
- Same pattern as Step 3: change `ptr: *anyopaque` → `self: *NullDb`, remove casts
- For functions that discard self (most of them), use `_: *NullDb`
- Remove the old static `const vtable` declaration
- Replace `fn database(self: *NullDb) Database` body

**Verify:** `zig fmt client/db/null.zig && zig build test` (all existing NullDb tests must pass unchanged)

### Step 5: Refactor `RocksDatabase` to use `Database.init`

**File:** `client/db/rocksdb.zig`

**Changes:**
- Same pattern: change `ptr: *anyopaque` → `self: *RocksDatabase` or `_: *RocksDatabase`
- Only `name_impl` uses `self`; rest discard it
- Remove old static vtable

**Verify:** `zig fmt client/db/rocksdb.zig && zig build test` (all existing RocksDatabase tests must pass unchanged)

### Step 6: Refactor `ReadOnlyDb` to use `Database.init`

**File:** `client/db/read_only.zig`

**Changes:**
- Same pattern: change `ptr: *anyopaque` → `self: *ReadOnlyDb`
- Complex implementations (put_impl, delete_impl, iterator_impl, snapshot_impl) keep their logic but operate on `self: *ReadOnlyDb` directly instead of casting
- Remove old static vtable

**Verify:** `zig fmt client/db/read_only.zig && zig build test` (all existing ReadOnlyDb tests must pass unchanged)

### Step 7: Refactor test mocks in `adapter.zig`

**File:** `client/db/adapter.zig`

Refactor 4 test mocks:
- **MockDb** (line 665): Change `get_impl`, `put_impl`, `delete_impl`, `contains_impl` from `*anyopaque` → `*MockDb`; use `Database.init` in `database()`
- **TrackingDb** (line 854): Change `put_impl`, `delete_impl` from `*anyopaque` → `*TrackingDb`; use `Database.init`
- **FailingDb** (line 1028): Change `put_impl`, `delete_impl` from `*anyopaque` → `*FailingDb`; use `Database.init`
- **AtomicDb** (line 1093): Change `put_impl`, `delete_impl`, `write_batch_impl` from `*anyopaque` → `*AtomicDb`; use `Database.init`
- **BatchDb** (inline in test, line 762): Change to use `Database.init`

Also: Remove the free-standing helper functions (`name_default`, `get_null`, `contains_false`, `iterator_unsupported`, `snapshot_unsupported`, `flush_noop`, `clear_noop`, `compact_noop`, `gather_metric_zero`) ONLY if they are no longer used after refactoring. If any test mock still references them (e.g., for default behavior), keep them but note they may be candidates for typed versions.

**Note:** The free-standing helpers (`get_null`, `flush_noop`, etc.) take `*anyopaque` signatures. They cannot be used directly with `Database.init` which expects `*const fn(self: *T, ...)`. Each mock must either:
- Provide its own typed function (preferred for clarity), OR
- We can add generic typed versions alongside `Database.init` (e.g., `Database.noop_flush`, `Database.null_get`) — but this is scope creep and should be deferred.

**Decision:** Each mock provides its own typed functions. Remove free-standing `*anyopaque` helpers only if nothing references them.

**Verify:** `zig fmt client/db/adapter.zig && zig build test` (all 20+ existing adapter tests must pass unchanged)

### Step 8: Final verification

- `zig fmt client/db/` — all files formatted
- `zig build` — clean build
- `zig build test` — all tests pass
- Grep for `@ptrCast(@alignCast` in `client/db/` — should only exist inside `Database.init`, `DbIterator.init`, and `DbSnapshot.init` wrappers (not in any backend file)

## Files to Create

None — all changes are in existing files.

## Files to Modify

| File | Change | Lines Affected |
|------|--------|----------------|
| `client/db/adapter.zig` | Add `Database.init` comptime helper + tests; refactor MockDb, TrackingDb, FailingDb, AtomicDb, BatchDb | ~405 (insert), ~665-1139 (modify) |
| `client/db/memory.zig` | Replace manual vtable with `Database.init` | ~308-377 |
| `client/db/null.zig` | Replace manual vtable with `Database.init` | ~59-165 |
| `client/db/rocksdb.zig` | Replace manual vtable with `Database.init` | ~121-185 |
| `client/db/read_only.zig` | Replace manual vtable with `Database.init` | ~295-396 |

## Tests to Write

1. **"Database.init generates correct vtable dispatch"** — Verify typed `self` is recovered correctly through the comptime wrapper by mutating a field and checking it.
2. **"Database.init with write_batch"** — Verify optional `write_batch` is wired through correctly, `supports_write_batch()` returns true.
3. **"Database.init without write_batch defaults to null"** — Verify `supports_write_batch()` returns false when `write_batch` is omitted.

All existing tests (~30+ across adapter.zig, memory.zig, null.zig, rocksdb.zig, read_only.zig) serve as regression tests and must pass without modification.

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Zig comptime anonymous struct with function pointers doesn't compile | Low | High | Pattern is proven by `DbIterator.init` and `DbSnapshot.init`; test Step 1 immediately |
| Static vtable lifetime — `&Wrapper.vtable` must outlive `Database` | Low | High | Same pattern as `DbIterator.init`; Zig guarantees comptime-generated statics have `'static` lifetime |
| Free-standing helper removal breaks something | Low | Medium | Only remove if grep confirms zero remaining references; step 7 handles carefully |
| NullDb's `var empty_iterator`/`var null_snapshot` — the mutable module-level vars | None | None | These are for `DbIterator.init`/`DbSnapshot.init`, not `Database.init`; unaffected |
| ReadOnlyDb's complex vtable impls fail after refactor | Low | Medium | The functions' bodies don't change — only the first parameter type changes from `*anyopaque` to `*ReadOnlyDb`, removing the manual cast |

## Acceptance Criteria Verification

| Criterion | How to Verify |
|-----------|--------------|
| Database struct has comptime init() helper | Inspect `client/db/adapter.zig`, verify `Database.init(comptime T, ptr, comptime fns)` exists |
| At least MemoryDatabase and NullDb use the new helper | Inspect `client/db/memory.zig` and `client/db/null.zig`, verify they call `Database.init(...)` |
| All existing tests pass without modification | `zig build test` — zero failures |
| No @ptrCast/@alignCast in backend vtable functions | `grep -rn '@ptrCast(@alignCast' client/db/` shows casts only inside `Database.init`, `DbIterator.init`, and `DbSnapshot.init` comptime wrappers in `adapter.zig` |
