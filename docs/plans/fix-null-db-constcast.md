# Plan: fix-null-db-constcast

## Overview

Eliminate 3 `@constCast` usages in `client/db/null.zig` by changing file-level `const` globals to `var` globals. This removes technically undefined behavior (casting away `const` on potentially read-only memory) with zero functional impact — both `EmptyIterator` and `NullSnapshot` are zero-sized structs with no mutable state.

**Scope:** 1 file, 5 line changes, 0 new allocations, 0 API changes.

## Root Cause

`DbIterator.init()` and `DbSnapshot.init()` in `adapter.zig` accept `ptr: *T` (mutable pointer). The file-level globals `empty_iterator` and `null_snapshot` are declared `const`, so `&empty_iterator` produces `*const EmptyIterator`. The code uses `@constCast` to bridge the gap. If the compiler places `const` globals in `.rodata`, this is UB per the Zig language spec even though no mutation actually occurs.

## Step-by-Step Implementation

### Step 1: Change `const` globals to `var`

**File:** `client/db/null.zig` (lines 160-161)

Change:
```zig
const empty_iterator = NullDb.EmptyIterator{};
const null_snapshot = NullDb.NullSnapshot{};
```

To:
```zig
var empty_iterator = NullDb.EmptyIterator{};
var null_snapshot = NullDb.NullSnapshot{};
```

**Rationale:** `var` tells the compiler to place these in writable memory. `&empty_iterator` now produces `*EmptyIterator` (mutable pointer), matching `DbIterator.init()`'s expected `*T` parameter. Both structs are zero-sized — there is no mutable state to protect.

### Step 2: Remove `@constCast` on line 111

**File:** `client/db/null.zig`, function `iterator_impl`

Change:
```zig
@constCast(&empty_iterator),
```

To:
```zig
&empty_iterator,
```

### Step 3: Remove `@constCast` on line 129

**File:** `client/db/null.zig`, function `NullSnapshot.snapshot_iterator`

Change:
```zig
@constCast(&empty_iterator),
```

To:
```zig
&empty_iterator,
```

### Step 4: Remove `@constCast` on line 141

**File:** `client/db/null.zig`, function `snapshot_impl`

Change:
```zig
@constCast(&null_snapshot),
```

To:
```zig
&null_snapshot,
```

### Step 5: Run `zig fmt` and `zig build`

```bash
zig fmt client/db/null.zig
zig build
```

### Step 6: Run tests

```bash
zig build test
```

Verify all 8 NullDb tests pass:
1. `"NullDb: get always returns null"`
2. `"NullDb: contains always returns false"`
3. `"NullDb: put returns StorageError"`
4. `"NullDb: put with null returns StorageError"`
5. `"NullDb: delete returns StorageError"`
6. `"NullDb: multiple instances are independent"`
7. `"NullDb: name is accessible via interface"`
8. `"NullDb: iterator yields no entries"`
9. `"NullDb: snapshot returns null and empty iterator"`

## Files to Modify

| File | Changes |
|------|---------|
| `client/db/null.zig` | Lines 111, 129, 141: remove `@constCast()` wrapper. Lines 160-161: `const` → `var`. |

## Files to Create

None.

## Tests

No new tests needed. The existing 8 tests in `client/db/null.zig` (lines 167-256) already exercise all 3 affected code paths:
- `"NullDb: iterator yields no entries"` — exercises `iterator_impl` (Step 2)
- `"NullDb: snapshot returns null and empty iterator"` — exercises `snapshot_impl` (Step 4) and `snapshot_iterator` (Step 3)

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `var` globals cause linker or compilation issues | Very low | Zig supports `var` at file scope; `MemoryDatabase` uses similar patterns |
| Thread safety concern with `var` globals | None | Both types are zero-sized with no state; all methods ignore `self` |
| Breaking downstream code that depends on `const` semantics | None | These are private (`const`, not `pub const`) file-scope variables, not exported |

## Verification Against Acceptance Criteria

1. **Zero `@constCast` usage in `client/db/null.zig`** — Verified by `grep -c '@constCast' client/db/null.zig` returning 0
2. **NullDb iterator and snapshot tests still pass** — Verified by `zig build test` with all 8 tests passing
3. **No new allocations introduced** — Verified by code inspection: `var` file-scope globals are statically allocated, no heap allocation added
