# db-001: Replace catch {} with explicit error handling in factory.zig test

## Ticket Summary

- **ID**: db-001
- **Title**: fix(db): Replace catch {} with explicit error handling in factory.zig test
- **Category**: db (Phase 0 - DB Abstraction Layer)

## Problem

`client/db/factory.zig:322` uses `catch {}` which silently suppresses errors. This violates:

1. **CLAUDE.md project rules**: "NEVER allow catch {} or silent error suppression"
2. **adapter.zig doc comment** (line 12): "Error handling: all operations return error unions — never use `catch {}`."

### The offending line

```zig
// factory.zig:322
_ = factory.createDb(DbSettings.init(.state, "/tmp")) catch {};
```

This is in the test `"DbFactory: init generates correct wrappers"` (lines 297-327). The test verifies that the vtable wrappers correctly dispatch calls and track side effects (incrementing `backend.value`). The `createDb` call intentionally returns `error.UnsupportedOperation`, and the test only cares that `backend.value` was incremented to 1. The error is expected — but `catch {}` silently swallows it.

## Fix: Use `try std.testing.expectError()`

Replace line 322:

```zig
// BEFORE (violates project rules)
_ = factory.createDb(DbSettings.init(.state, "/tmp")) catch {};

// AFTER (explicit error assertion)
try std.testing.expectError(error.UnsupportedOperation, factory.createDb(DbSettings.init(.state, "/tmp")));
```

This is the correct approach because:
- It documents the expected error explicitly
- It will fail if the error type changes unexpectedly
- It matches the pattern already used in the first test (`"DbFactory: vtable dispatch works with mock factory"`, line 285)

## Relevant Files

| File | Lines | Purpose |
|------|-------|---------|
| `client/db/factory.zig` | 322 | Line with `catch {}` violation |
| `client/db/factory.zig` | 297-327 | Full test: `"DbFactory: init generates correct wrappers"` |
| `client/db/factory.zig` | 258-295 | Reference test with correct `expectError` pattern |
| `client/db/adapter.zig` | 12 | Doc comment: "never use `catch {}`" |

## Nethermind Reference

| File | Purpose |
|------|---------|
| `nethermind/src/Nethermind/Nethermind.Db/IDbFactory.cs` | Factory interface — `CreateDb` throws on error, never silently swallows |
| `nethermind/src/Nethermind/Nethermind.Db/MemDbFactory.cs` | In-memory factory implementation |
| `nethermind/src/Nethermind/Nethermind.Db/NullRocksDbFactory.cs` | Null factory — `throw new InvalidOperationException()` (explicit, not swallowed) |

## Voltaire APIs

No Voltaire APIs are directly relevant. The DB factory is an internal abstraction layer. The fix is a test quality improvement only.

## Spec Files

No Ethereum specs are relevant. Phase 0 DB is an internal abstraction with no spec dependencies (per `prd/ETHEREUM_SPECS_REFERENCE.md`).

## Test Fixtures

No external test fixtures. Phase 0 uses unit tests only (per `prd/GUILLOTINE_CLIENT_PLAN.md`).

## Existing Pattern to Follow

The first test in factory.zig (line 285) already uses the correct pattern:

```zig
// factory.zig:285 — CORRECT pattern
try std.testing.expectError(error.UnsupportedOperation, factory.createDb(DbSettings.init(.state, "/tmp/state")));
try std.testing.expectEqual(@as(usize, 1), mock.create_count);
```

## Grep: All catch {} in DB module

Only one violation exists:

```
client/db/adapter.zig:12:/// Error handling: all operations return error unions — never use `catch {}`.  (doc comment)
client/db/factory.zig:322:    _ = factory.createDb(DbSettings.init(.state, "/tmp")) catch {};           (VIOLATION)
```

## Scope

- **Files to modify**: 1 (`client/db/factory.zig`)
- **Lines to change**: 1 (line 322)
- **Risk**: Zero — test-only change, no production code affected
- **Testing**: Run `zig test` on `client/db/factory.zig` to verify
