# Research Context: fix-null-db-constcast

## Ticket
- **ID**: fix-null-db-constcast
- **Title**: Eliminate @constCast in NullDb iterator/snapshot globals
- **Category**: phase-0-db

## Problem Description

`client/db/null.zig` uses `@constCast` 3 times (lines 111, 129, 141) to cast `const` file-level globals (`empty_iterator` and `null_snapshot`) to mutable pointers. The `DbIterator.init()` and `DbSnapshot.init()` functions require `*T` (mutable pointer) parameters, but these globals are declared as `const`:

```zig
const empty_iterator = NullDb.EmptyIterator{};   // line 160
const null_snapshot = NullDb.NullSnapshot{};      // line 161
```

The `@constCast` usages:
- **Line 111**: `@constCast(&empty_iterator)` — in `iterator_impl`, passed to `DbIterator.init()`
- **Line 129**: `@constCast(&empty_iterator)` — in `NullSnapshot.snapshot_iterator`, passed to `DbIterator.init()`
- **Line 141**: `@constCast(&null_snapshot)` — in `snapshot_impl`, passed to `DbSnapshot.init()`

This is **technically undefined behavior** in Zig: if the compiler places `const` globals in read-only memory (e.g., `.rodata` section), casting away `const` and passing as a mutable pointer violates the language's safety guarantees. Even though no actual mutation occurs (all vtable functions ignore `self`), the Zig language spec makes this UB.

## Fix Strategy

Change the file-level globals from `const` to `var`:

```zig
var empty_iterator = NullDb.EmptyIterator{};
var null_snapshot = NullDb.NullSnapshot{};
```

This is safe because:
1. `EmptyIterator` and `NullSnapshot` are zero-sized structs — no mutable state to protect.
2. The `var` declaration tells the compiler to place them in writable memory, making `&empty_iterator` produce a `*EmptyIterator` (mutable pointer) directly.
3. No `@constCast` needed — the types match what `DbIterator.init()` and `DbSnapshot.init()` expect.

## Reference Files

### Existing Implementation
- **`client/db/null.zig`** — The file containing the 3 `@constCast` usages (lines 111, 129, 141, 160-161)
- **`client/db/adapter.zig`** — Defines `DbIterator.init()` (line 216) and `DbSnapshot.init()` (line 277) which require `*T` mutable pointers

### Correct Pattern (MemoryDatabase)
- **`client/db/memory.zig`** — Shows the correct approach: `MemorySnapshot` and iterators are heap-allocated via `allocator.create()`, producing naturally mutable `*T` pointers (lines 240-245, 252-262). NullDb can't use heap allocation (zero-alloc null object), so `var` globals are the appropriate alternative.

### Nethermind Reference
- **`nethermind/src/Nethermind/Nethermind.Db/NullDb.cs`** — Singleton pattern with lazy init. Returns empty collections `[]` for `GetAll()`, `GetAllKeys()`, `GetAllValues()`. No iterator/snapshot pattern — C# doesn't have this const/var distinction.

### Voltaire APIs
- Voltaire does not provide a raw KV persistence interface. The `Database`, `DbIterator`, and `DbSnapshot` types in `adapter.zig` are custom to this project and fill the gap between Voltaire's typed state management (StateManager/JournaledState) and the persistence layer.

### Ethereum Specs
- **N/A** — This is an internal abstraction (phase-0-db). No Ethereum specs, EIPs, or execution-specs are relevant. The PRD (`prd/ETHEREUM_SPECS_REFERENCE.md`) confirms: "Phase 0: DB Abstraction — Specs: N/A (internal abstraction), Tests: Unit tests only."

### Test Fixtures
- **N/A** — No ethereum-tests or execution-spec-tests fixtures apply. The existing unit tests in `null.zig` (lines 167-256) cover all NullDb behavior and will serve as regression tests.

## Existing Tests

The following tests in `client/db/null.zig` exercise the affected code paths:
1. `"NullDb: iterator yields no entries"` (line 231) — calls `iterator_impl` which uses `@constCast(&empty_iterator)`
2. `"NullDb: snapshot returns null and empty iterator"` (line 242) — calls `snapshot_impl` which uses `@constCast(&null_snapshot)`, and snapshot's `iterator()` which uses `@constCast(&empty_iterator)`

These tests must continue passing after the fix.

## Implementation Checklist

1. Change `const empty_iterator` to `var empty_iterator` (line 160)
2. Change `const null_snapshot` to `var null_snapshot` (line 161)
3. Remove `@constCast(...)` wrapper on line 111, replacing with `&empty_iterator`
4. Remove `@constCast(...)` wrapper on line 129, replacing with `&empty_iterator`
5. Remove `@constCast(...)` wrapper on line 141, replacing with `&null_snapshot`
6. Run `zig fmt client/db/null.zig`
7. Run `zig build` to verify compilation
8. Run tests to verify all 8 NullDb tests still pass

## Risk Assessment

- **Risk**: Very low. Zero-sized structs have no mutable state. The change is purely a correctness fix for potential UB.
- **Scope**: Single file (`client/db/null.zig`), 5 line changes.
- **Breaking changes**: None. Public API unchanged.
