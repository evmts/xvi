# Test Suite Findings

## phase-0-db
### Status: PASSING
### What works:
- All 165 unit tests pass across 10 modules
- Test breakdown by module:
  - `columns.zig` — 37 tests (ColumnsDb, ColumnsWriteBatch, ColumnDbSnapshot, MemColumnsDb, ReadOnlyColumnsDb)
  - `adapter.zig` — 30 tests (Database vtable, WriteBatch, DbName, OwnedDatabase, ReadFlags/WriteFlags)
  - `read_only.zig` — 25 tests (ReadOnlyDb overlay, clear temp changes, write-through)
  - `memory.zig` — 23 tests (MemoryDatabase put/get/delete, iterators, snapshots, metrics)
  - `factory.zig` — 17 tests (DbFactory vtable, MemDbFactory, NullDbFactory, ReadOnlyDbFactory)
  - `rocksdb.zig` — 10 tests (RocksDatabase stub, DbSettings)
  - `null.zig` — 9 tests (NullDb null-object pattern, iterators, snapshots)
  - `read_only_provider.zig` — 6 tests (ReadOnlyDbProvider)
  - `provider.zig` — 4 tests (DbProvider registry)
  - `root.zig` — 3 integration tests (factory → provider wiring)
- `zig fmt` passes cleanly on all DB files
- All tests use `std.testing.allocator` for leak detection — no leaks
- Comprehensive error handling tests (OOM propagation, StorageError, retry semantics)
- Tests run via direct `zig test` invocation (bypassing build system issue)

### What was tried:
- `zig build test-db` — FAILS due to build system issue in Voltaire dependency (see below)
- `zig test --dep primitives -Mroot=client/db/root.zig -Mprimitives=.../primitives/root.zig` — PASSES (165/165)
- `zig fmt --check client/db/` — PASSES

### What's blocked:
- **`zig build test-db` build system crash**: The `zig build` command panics with `unable to find artifact 'wallycore'` in Voltaire's `addTypeScriptNativeBuild` function. This is NOT a DB module issue — it's a Voltaire build.zig infrastructure problem where `libwally_core_dep.artifact("wallycore")` fails at line 971 of `voltaire/build.zig`. The function `addTypeScriptNativeBuild` doesn't guard against missing artifacts unlike the top-level code (line 60) which uses `lazyDependency` with a null-break pattern.
- **RocksDB backend is a stub**: All RocksDB operations return `error.StorageError`. The `RocksDatabase` type exists for compilation compatibility but has no real FFI implementation. This is expected for Phase 0.
- **No external test suite**: The DB abstraction layer is an internal module with no external test fixtures (correct per the plan — Phase 0 is "internal abstraction").

### Needs human intervention:
- **Voltaire build system fix**: The `wallycore` artifact panic needs to be fixed in `voltaire/build.zig` line 971. The `addTypeScriptNativeBuild` function should use `lazyDependency` with a null guard (like line 60 does), or the dependency should be installed. This blocks `zig build test-db` and all other `zig build` targets.
  - Alternatively: install `libwally-core` system dependency if that's what's expected.

### Suggested tickets:
- **BLOCKER** `fix(voltaire): Guard wallycore artifact lookup in addTypeScriptNativeBuild` — The function at line 971 of `voltaire/build.zig` unconditionally calls `libwally_core_dep.artifact("wallycore")` without null-checking the lazy dependency. Should mirror the pattern at line 60 that uses `orelse break :blk null`. This blocks ALL `zig build` commands in xvi.
- `feat(db): Implement RocksDB FFI backend` — Replace the stub `RocksDatabase` with actual RocksDB C API bindings. Low priority until Phase 4+ needs persistent storage.
- `test(db): Add stress/fuzz tests for WriteBatch edge cases` — The current test coverage is solid but could benefit from property-based testing (e.g., random sequences of put/delete/commit/clear operations).
