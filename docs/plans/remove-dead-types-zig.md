# Plan: remove-dead-types-zig

## Overview

Delete `client/db/types.zig` — a dead file that imports `primitives.Db` (which does not exist in Voltaire) and is never imported by any module. All types it attempts to re-export are already natively defined in `adapter.zig` and re-exported through `root.zig`. The 8 test blocks in the file can never execute because the file is never compiled.

This is a zero-risk deletion with no code modifications required in any other file.

## Evidence of Dead Code

1. **`primitives.Db` does not exist** — Voltaire provides `StateManager`, `JournaledState`, caches, but no raw KV `Db` interface.
2. **Zero imports** — `grep -r 'types\.zig' client/` and `grep -r '@import("types' client/db/` return no matches.
3. **`root.zig` does not reference it** — All sub-modules are listed (`adapter`, `memory`, `null_db`, `rocksdb`, `read_only`, `provider`, `ro_provider`) but `types` is absent.
4. **Types are duplicated** — Every type `types.zig` tries to re-export (`Error`, `DbName`, `ReadFlags`, `WriteFlags`, `DbMetric`, `DbValue`, `DbEntry`, `DbIterator`, `DbSnapshot`) is already defined natively in `adapter.zig` and re-exported by `root.zig`.
5. **Build system has no reference** — `build.zig` does not mention `types.zig`.

## Step-by-step Implementation

### Step 1: Delete `client/db/types.zig`

- **Action:** `git rm client/db/types.zig`
- **Rationale:** File cannot compile (references non-existent `primitives.Db`), is never imported, and all its types are already defined in `adapter.zig`.

### Step 2: Verify build succeeds

- **Action:** `zig build`
- **Expected:** Clean build with no errors. Since no module imports `types.zig`, removing it changes nothing in the compilation graph.

### Step 3: Verify `zig build test-db` passes

- **Action:** `zig build test-db` (or equivalent DB test target)
- **Expected:** All existing DB tests pass. The 8 tests in `types.zig` were never compiled, so their removal has no effect on the test suite.

### Step 4: Verify `root.zig` `refAllDecls` test passes

- **Action:** `zig build test` (which includes the `refAllDecls` test in `root.zig`)
- **Expected:** Passes. `root.zig`'s `refAllDecls` only covers its own imports (`adapter`, `memory`, `null_db`, `rocksdb`, `read_only`, `provider`, `ro_provider`), and `types` was never listed.

## Files to Create

None.

## Files to Modify

None. No other file references `types.zig`.

## Files to Delete

| File | Reason |
|------|--------|
| `client/db/types.zig` | Dead code: imports non-existent `primitives.Db`, never imported, duplicates `adapter.zig` types |

## Tests to Write

None required. This is a pure deletion of dead code. The existing test suite (`zig build test-db`, `zig build test`, `refAllDecls`) provides sufficient coverage to verify no regression.

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Some module imports `types.zig` that grep missed | Near zero — confirmed with both filename and `@import` pattern searches | Run full build + test suite after deletion |
| Build system references `types.zig` | Zero — confirmed `build.zig` has no reference | Run `zig build` after deletion |
| Future code expects `types.zig` to exist | Low — `adapter.zig` is the canonical source, and `root.zig` re-exports from it | Document in commit message that types come from `adapter.zig` via `root.zig` |

## Verification Against Acceptance Criteria

| Criterion | How to Verify |
|-----------|---------------|
| `client/db/types.zig` is deleted | `ls client/db/types.zig` returns "No such file" |
| No module in `client/db/` references `types.zig` | `grep -r 'types' client/db/*.zig` shows no import references (already confirmed) |
| `zig build test-db` still passes | Run `zig build test-db` and confirm exit code 0 |
| `root.zig` `refAllDecls` test still passes | Run `zig build test` and confirm the `refAllDecls` test in `client/db/root.zig` passes |
