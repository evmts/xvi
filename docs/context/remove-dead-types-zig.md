# Research Context: remove-dead-types-zig

## Ticket Summary

Remove `client/db/types.zig` — a dead file that imports `primitives.Db` (which does not exist in Voltaire) and is never imported by any module in the DB layer. All 8 test blocks in it can never execute because the file is never referenced.

## Evidence of Dead Code

### 1. `primitives.Db` does not exist in Voltaire
- Searched `/Users/williamcory/voltaire/packages/voltaire-zig/src/` for `pub const Db` — **no matches**.
- Voltaire does not provide a raw KV persistence interface; it provides higher-level state management (`StateManager`, `JournaledState`, caches).
- The `adapter.zig` module acknowledges this explicitly in its doc comment (lines 14-27): "Voltaire does not provide a raw KV persistence interface, so this abstraction fills that gap."

### 2. `types.zig` is never imported
- Grepped `client/db/` and `client/` for `@import("types` — **no matches**.
- Grepped entire repo for `types.zig` reference in `.zig` files — **no matches** outside the file itself.
- `root.zig` imports all sub-modules (`adapter`, `memory`, `null_db`, `rocksdb`, `read_only`, `provider`, `ro_provider`) but **not `types`**.
- `root.zig` re-exports all types from `adapter.zig` directly.

### 3. All types already defined in `adapter.zig`
The same types that `types.zig` tries to re-export from `primitives.Db` are **already defined natively** in `adapter.zig`:
- `Error` (adapter.zig:40-53)
- `DbName` (adapter.zig:63+)
- `ReadFlags` (defined in adapter.zig)
- `WriteFlags` (defined in adapter.zig)
- `DbMetric` (defined in adapter.zig)
- `DbValue` (defined in adapter.zig)
- `DbEntry` (defined in adapter.zig)
- `DbIterator` (defined in adapter.zig)
- `DbSnapshot` (defined in adapter.zig)

### 4. Tests can never execute
The file has 8 `test` blocks (lines 24-238) testing `DbName`, `ReadFlags`, `WriteFlags`, `DbValue`, `DbEntry`, `DbIterator`, `DbSnapshot`. Since the file is never imported and never compiled, these tests are dead code.

## Files to Modify

| File | Action |
|------|--------|
| `client/db/types.zig` | **DELETE** — entire file |

No other files need changes since nothing imports `types.zig`.

## Nethermind Reference

Nethermind's DB layer defines types in their interface files, not in a separate "types" file:
- `nethermind/src/Nethermind/Nethermind.Db/IDb.cs` — Interface with `DbMetric` struct
- `nethermind/src/Nethermind/Nethermind.Db/DbNames.cs` — Static class with 15 DB name constants

Our `adapter.zig` already mirrors this pattern correctly.

## Voltaire APIs

No Voltaire DB primitives exist. Voltaire provides:
- `StateManager` / `JournaledState` — typed state management (higher-level)
- `AccountCache`, `StorageCache`, `ContractCache` — in-memory caches
- These sit *above* the raw KV layer, not below it

## PRD Reference

From `prd/GUILLOTINE_CLIENT_PLAN.md` Phase 0 (DB Abstraction Layer):
- Key components: `client/db/adapter.zig`, `client/db/rocksdb.zig`, `client/db/memory.zig`
- `types.zig` is not listed as a key component

From `prd/ETHEREUM_SPECS_REFERENCE.md` Phase 0:
- Specs: N/A (internal abstraction)
- Tests: Unit tests only
- No external test fixtures needed

## Spec References

N/A — DB abstraction is an internal concern, not governed by Ethereum specs.

## Test Fixtures

N/A — no external test fixtures apply to this change.

## Risk Assessment

**Zero risk** — removing a file that:
1. Cannot compile (references non-existent `primitives.Db`)
2. Is never imported by any module
3. Duplicates types already defined in `adapter.zig`
4. Contains tests that never run

## Implementation Plan

1. `git rm client/db/types.zig`
2. Verify `zig build` still works
3. Verify `zig build test` still works (no test should be affected)
