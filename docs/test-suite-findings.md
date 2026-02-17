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

## phase-1-trie
### Status: PASSING
### What works:
- **All 25 ethereum-tests/TrieTests fixture vectors pass** across 5 fixture files
- **All 23 Zig tests pass** (fixture tests + unit tests combined)
- Test breakdown by fixture file:
  - `trieanyorder.json` — 7 vectors (singleItem, dogs, puppy, foo, smallValues, testy, hex)
  - `trieanyorder_secureTrie.json` — 7 vectors (same names, keys hashed with keccak256)
  - `trietest.json` — 5 vectors (emptyValues, branchingTests, jeff, insert-middle-leaf, branch-value-update)
  - `trietest_secureTrie.json` — 3 vectors (emptyValues, branchingTests, jeff)
  - `hex_encoded_securetrie_test.json` — 3 vectors (test1, test2, test3)
- Unit tests cover: empty trie root, input validation, single/multi entry tries, secure trie hashing, hex-encoded keys
- Two independent test runners both pass:
  - `client/trie/fixtures.zig` — references JSON fixtures by relative path, used by `zig build test-trie` (blocked by build system but works via direct `zig test`)
  - `guillotine-mini/test/trie/fixtures.zig` — full fixture harness with detailed error reporting, used by `zig build test-trie-fixtures`
- Implementation correctly handles:
  - Ordered and any-order insertion semantics
  - Key updates (last value wins) and deletions (null values)
  - Hex-prefix (HP) encoding for leaf/extension nodes
  - Node inlining rule (< 32 bytes → inline, >= 32 bytes → keccak256 hash)
  - Secure trie semantics (keccak256 key pre-hashing)
  - Hex-encoded key/value pairs
- `zig fmt` passes cleanly on all trie files
- All tests use `std.testing.allocator` for leak detection — no memory leaks

### What was tried:
- `zig build test-trie` — FAILS due to Voltaire wallycore build system crash (same as phase-0-db)
- `zig build test-trie-fixtures` — FAILS due to same wallycore issue
- Direct `zig test` with manual module imports — **PASSES (23/23)**:
  ```bash
  zig test \
    --dep primitives --dep crypto --dep client_trie \
    -Mroot=client/trie/root.zig \
    -Mc_kzg=../voltaire/packages/voltaire-zig/lib/c-kzg-4844/bindings/zig/root.zig \
    --dep c_kzg --dep primitives \
    -I../voltaire/packages/voltaire-zig/lib \
    -Mcrypto=../voltaire/packages/voltaire-zig/src/crypto/root.zig \
    --dep crypto \
    -Mprimitives=../voltaire/packages/voltaire-zig/src/primitives/root.zig
  ```
- ethereum-tests submodule initialized successfully (`git submodule update --init --depth 1 ethereum-tests`)

### What's blocked:
- **`zig build test-trie` / `zig build test-trie-fixtures` build system crash**: Same `wallycore` artifact panic as phase-0-db. The Voltaire build.zig crashes at line 971 (`libwally_core_dep.artifact("wallycore")`) blocking all `zig build` targets. Tests can only run via direct `zig test` invocation.
- **`trietestnextprev.json` not tested**: This fixture tests trie iteration (prev/next key navigation), which is a different capability than root hash computation. The current implementation only supports `trie_root()` / `secure_trie_root()` — it does not implement key iteration/traversal. 1 test vector with 12 assertions is untested.

### Needs human intervention:
- **Voltaire build system fix** (same as phase-0-db): The `wallycore` artifact panic in `voltaire/build.zig:971` blocks `zig build test-trie` and `zig build test-trie-fixtures`. The `packages/voltaire-zig/lib/libwally-core/` directory exists but is empty (no `build.zig`). Either populate the libwally-core dependency or fix the guard at line 967-971 to handle missing artifacts gracefully.

### Suggested tickets:
- **BLOCKER** `fix(voltaire): Guard wallycore artifact lookup in addTypeScriptNativeBuild` — Same as phase-0-db. Blocks ALL `zig build` commands.
- `feat(trie): Implement key iteration/traversal for trietestnextprev.json` — The current trie module only computes root hashes from flat key-value maps. To pass `trietestnextprev.json`, implement `next(key)` / `prev(key)` traversal on the trie structure. Low priority — iteration is needed for snap sync and state inspection, not basic block execution.
- `test(trie): Add trietestnextprev.json fixture runner` — Once iteration is implemented, add a test runner for the 12 prev/next assertions in `trietestnextprev.json`.
