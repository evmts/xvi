import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Either from "effect/Either";
import { Address, Hash, Hex, RuntimeCode } from "voltaire-effect/primitives";
import {
  EMPTY_ACCOUNT,
  EMPTY_CODE_HASH,
  isTotallyEmpty,
  type AccountStateType,
} from "./Account";
import {
  WorldStateTest,
  accountExistsAndIsEmpty,
  hasAccount,
  MissingAccountError,
  UnknownSnapshotError,
  clear,
  commitSnapshot,
  destroyAccount,
  destroyTouchedEmptyAccounts,
  getAccount,
  getAccountOptional,
  getCode,
  getStorage,
  getStorageOriginal,
  markAccountCreated,
  restoreSnapshot,
  setAccount,
  setCode,
  setStorage,
  takeSnapshot,
  wasAccountCreated,
} from "./State";

const makeAccount = (
  overrides: Partial<Omit<AccountStateType, "__tag">> = {},
): AccountStateType => ({
  ...EMPTY_ACCOUNT,
  ...overrides,
});

const makeAddress = (lastByte: number): Address.AddressType => {
  const addr = Address.zero();
  addr[addr.length - 1] = lastByte;
  return addr;
};

type StorageSlotType = Parameters<typeof getStorage>[1];
type StorageValueType = Parameters<typeof setStorage>[2];

const makeSlot = (lastByte: number): StorageSlotType => {
  const value = new Uint8Array(32);
  value[value.length - 1] = lastByte;
  return value as StorageSlotType;
};

const makeStorageValue = (byte: number): StorageValueType => {
  const value = new Uint8Array(32);
  value.fill(byte);
  return value as StorageValueType;
};

const storageValueHex = (value: Uint8Array) => Hex.fromBytes(value);
const ZERO_STORAGE_VALUE = makeStorageValue(0);

const EMPTY_CODE = new Uint8Array(0) as RuntimeCode.RuntimeCodeType;
const SAMPLE_CODE = new Uint8Array([
  0x60, 0x00, 0x60, 0x00,
]) as RuntimeCode.RuntimeCodeType;

const codeHex = (code: Uint8Array) => Hex.fromBytes(code);

const provideWorldState = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
  effect.pipe(Effect.provide(WorldStateTest));

describe("WorldState", () => {
  it.effect("returns null for missing accounts", () =>
    provideWorldState(
      Effect.gen(function* () {
        const account = yield* getAccountOptional(Address.zero());
        assert.strictEqual(account, null);
      }),
    ),
  );

  it.effect("returns EMPTY_ACCOUNT for missing accounts", () =>
    provideWorldState(
      Effect.gen(function* () {
        const account = yield* getAccount(Address.zero());
        assert.strictEqual(isTotallyEmpty(account), true);
      }),
    ),
  );

  it.effect("accountExistsAndIsEmpty is false for missing accounts", () =>
    provideWorldState(
      Effect.gen(function* () {
        const existsAndIsEmpty = yield* accountExistsAndIsEmpty(Address.zero());
        assert.strictEqual(existsAndIsEmpty, false);
      }),
    ),
  );
  it.effect("hasAccount reflects presence in world state", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(0xfe);
        assert.strictEqual(yield* hasAccount(addr), false);
        yield* setAccount(addr, makeAccount({ nonce: 1n }));
        assert.strictEqual(yield* hasAccount(addr), true);
        yield* destroyAccount(addr);
        assert.strictEqual(yield* hasAccount(addr), false);
      }),
    ),
  );

  it.effect("accountExistsAndIsEmpty matches EIP-161 emptiness semantics", () =>
    provideWorldState(
      Effect.gen(function* () {
        const empty = makeAddress(0xa1);
        const nonEmpty = makeAddress(0xa2);
        const nonEmptyStorageRoot = new Uint8Array(32);
        nonEmptyStorageRoot[nonEmptyStorageRoot.length - 1] = 0x01;

        yield* setAccount(
          empty,
          makeAccount({
            storageRoot: nonEmptyStorageRoot as AccountStateType["storageRoot"],
          }),
        );
        yield* setAccount(nonEmpty, makeAccount({ nonce: 1n }));

        assert.strictEqual(yield* accountExistsAndIsEmpty(empty), true);
        assert.strictEqual(yield* accountExistsAndIsEmpty(nonEmpty), false);
      }),
    ),
  );

  it.effect("sets, updates, and deletes accounts", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(1);
        yield* setAccount(addr, makeAccount({ nonce: 1n }));

        const created = yield* getAccountOptional(addr);
        assert.notStrictEqual(created, null);
        assert.strictEqual(created?.nonce, 1n);

        yield* setAccount(addr, makeAccount({ nonce: 2n }));
        const updated = yield* getAccountOptional(addr);
        assert.strictEqual(updated?.nonce, 2n);

        yield* destroyAccount(addr);
        const deleted = yield* getAccountOptional(addr);
        assert.strictEqual(deleted, null);
      }),
    ),
  );

  it.effect(
    "destroyTouchedEmptyAccounts deletes only touched empty accounts",
    () =>
      provideWorldState(
        Effect.gen(function* () {
          const touchedEmpty = makeAddress(0xb1);
          const touchedNonEmpty = makeAddress(0xb2);
          const untouchedEmpty = makeAddress(0xb3);
          const missingTouched = makeAddress(0xb4);

          yield* setAccount(touchedEmpty, makeAccount());
          yield* setAccount(touchedNonEmpty, makeAccount({ nonce: 1n }));
          yield* setAccount(untouchedEmpty, makeAccount());

          yield* destroyTouchedEmptyAccounts([
            touchedEmpty,
            touchedNonEmpty,
            missingTouched,
          ]);

          const deleted = yield* getAccountOptional(touchedEmpty);
          assert.strictEqual(deleted, null);

          const preservedNonEmpty = yield* getAccountOptional(touchedNonEmpty);
          assert.notStrictEqual(preservedNonEmpty, null);
          assert.strictEqual(preservedNonEmpty?.nonce, 1n);

          const untouched = yield* getAccountOptional(untouchedEmpty);
          assert.notStrictEqual(untouched, null);
        }),
      ),
  );

  it.effect("returns empty code for missing accounts", () =>
    provideWorldState(
      Effect.gen(function* () {
        const code = yield* getCode(Address.zero());
        assert.strictEqual(codeHex(code), codeHex(EMPTY_CODE));
      }),
    ),
  );

  it.effect("sets and clears contract code", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(8);
        yield* setCode(addr, SAMPLE_CODE);
        const stored = yield* getCode(addr);
        assert.strictEqual(codeHex(stored), codeHex(SAMPLE_CODE));

        yield* setCode(addr, EMPTY_CODE);
        const cleared = yield* getCode(addr);
        assert.strictEqual(codeHex(cleared), codeHex(EMPTY_CODE));
      }),
    ),
  );

  it.effect(
    "setting empty code on a missing account is a no-op (does not materialize account)",
    () =>
      provideWorldState(
        Effect.gen(function* () {
          const addr = makeAddress(0xe3);
          const empty = EMPTY_CODE;
          // no prior account
          assert.strictEqual(yield* getAccountOptional(addr), null);
          // set empty code → should not create account or journal
          yield* setCode(addr, empty);
          const stillMissing = yield* getAccountOptional(addr);
          assert.strictEqual(stillMissing, null);
          const bytes = yield* getCode(addr);
          assert.strictEqual(codeHex(bytes), codeHex(empty));
        }),
      ),
  );

  it.effect(
    "setCode is idempotent on identical bytes and does not journal spurious updates",
    () =>
      provideWorldState(
        Effect.gen(function* () {
          const addr = makeAddress(0xde);
          const code = SAMPLE_CODE;
          const snap1 = yield* takeSnapshot();
          yield* setCode(addr, code);
          const snap2 = yield* takeSnapshot();
          // same bytes
          yield* setCode(addr, code);
          const after = yield* getCode(addr);
          assert.strictEqual(codeHex(after), codeHex(code));
          // restoring to snap2 should change nothing
          yield* restoreSnapshot(snap2);
          const still = yield* getCode(addr);
          assert.strictEqual(codeHex(still), codeHex(code));
          // cleanup
          yield* restoreSnapshot(snap1);
        }),
      ),
  );

  it.effect(
    "setAccount identical value is a no-op and does not double-journal",
    () =>
      provideWorldState(
        Effect.gen(function* () {
          const addr = makeAddress(0xdf);
          const acc = makeAccount({ nonce: 2n });
          const s1 = yield* takeSnapshot();
          yield* setAccount(addr, acc);
          const s2 = yield* takeSnapshot();
          yield* setAccount(addr, acc);
          // roll back to s2; account should remain
          yield* restoreSnapshot(s2);
          const present = yield* getAccountOptional(addr);
          assert.notStrictEqual(present, null);
          assert.strictEqual(present?.nonce, 2n);
          // cleanup
          yield* restoreSnapshot(s1);
        }),
      ),
  );

  it.effect("markAccountCreated fails if called before takeSnapshot", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(0xe0);
        const res = yield* Effect.either(markAccountCreated(addr));
        assert.strictEqual(Either.isLeft(res), true);
      }),
    ),
  );

  it.effect(
    "destroyAccount clears storage; setAccount(null) does not implicitly clear storage",
    () =>
      provideWorldState(
        Effect.gen(function* () {
          const addr = makeAddress(0xe1);
          const slot = makeSlot(0x0a);
          const value = makeStorageValue(0x11);
          yield* setAccount(addr, makeAccount({ nonce: 1n }));
          yield* setStorage(addr, slot, value);
          // setAccount(null) should remove account but not forcibly sweep storage (destroyAccount does)
          yield* setAccount(addr, null);
          // storage read via getStorage returns ZERO since account missing
          const after = yield* getStorage(addr, slot);
          assert.strictEqual(
            storageValueHex(after),
            storageValueHex(ZERO_STORAGE_VALUE),
          );
          // recreate and set storage; destroyAccount should clear explicitly
          yield* setAccount(addr, makeAccount({ nonce: 1n }));
          yield* setStorage(addr, slot, value);
          yield* destroyAccount(addr);
          const cleared = yield* getStorage(addr, slot);
          assert.strictEqual(
            storageValueHex(cleared),
            storageValueHex(ZERO_STORAGE_VALUE),
          );
        }),
      ),
  );

  it.effect(
    "clear includes TODO validation hook for EMPTY_STORAGE_ROOT invariants (non-throwing)",
    () =>
      provideWorldState(
        Effect.gen(function* () {
          const addr = makeAddress(0xe2);
          yield* setAccount(addr, makeAccount({ nonce: 1n }));
          // should not throw
          yield* clear();
          const missing = yield* getAccountOptional(addr);
          assert.strictEqual(missing, null);
        }),
      ),
  );

  it.effect("updates account.codeHash when setting/clearing code", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(0xcc);
        // Initially code hash is EMPTY
        const initial = yield* getAccount(addr);
        assert.strictEqual(
          Hex.fromBytes(initial.codeHash),
          Hex.fromBytes(EMPTY_CODE_HASH),
        );

        // Set non-empty code -> codeHash = keccak256(code)
        yield* setCode(addr, SAMPLE_CODE);
        const expected = yield* Hash.keccak256(SAMPLE_CODE);
        const afterSet = yield* getAccount(addr);
        assert.strictEqual(
          Hex.fromBytes(afterSet.codeHash),
          Hex.fromBytes(expected),
        );

        // Clear code -> codeHash = EMPTY_CODE_HASH
        yield* setCode(addr, EMPTY_CODE);
        const afterClear = yield* getAccount(addr);
        assert.strictEqual(
          Hex.fromBytes(afterClear.codeHash),
          Hex.fromBytes(EMPTY_CODE_HASH),
        );
      }),
    ),
  );

  it.effect("restores code and account.codeHash on snapshot rollback", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(0xcd);
        yield* setCode(addr, SAMPLE_CODE);
        const expected = yield* Hash.keccak256(SAMPLE_CODE);
        const snapshot = yield* takeSnapshot();

        // Mutate to empty
        yield* setCode(addr, EMPTY_CODE);
        const mutated = yield* getAccount(addr);
        assert.strictEqual(
          Hex.fromBytes(mutated.codeHash),
          Hex.fromBytes(EMPTY_CODE_HASH),
        );

        // Restore -> both code and codeHash revert
        yield* restoreSnapshot(snapshot);
        const restoredCode = yield* getCode(addr);
        const restoredAccount = yield* getAccount(addr);
        assert.strictEqual(codeHex(restoredCode), codeHex(SAMPLE_CODE));
        assert.strictEqual(
          Hex.fromBytes(restoredAccount.codeHash),
          Hex.fromBytes(expected),
        );
      }),
    ),
  );

  it.effect("restores code changes on snapshot rollback", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(16);
        yield* setCode(addr, SAMPLE_CODE);
        const snapshot = yield* takeSnapshot();
        yield* setCode(addr, EMPTY_CODE);

        yield* restoreSnapshot(snapshot);
        const restored = yield* getCode(addr);
        assert.strictEqual(codeHex(restored), codeHex(SAMPLE_CODE));
      }),
    ),
  );

  it.effect("returns zero for missing storage slots", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(10);
        const slot = makeSlot(0);
        const value = yield* getStorage(addr, slot);
        assert.strictEqual(
          storageValueHex(value),
          storageValueHex(ZERO_STORAGE_VALUE),
        );
      }),
    ),
  );

  it.effect("sets, updates, and clears storage slots", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(11);
        const slot = makeSlot(1);
        const valueA = makeStorageValue(5);
        const valueB = makeStorageValue(9);

        yield* setAccount(addr, makeAccount({ nonce: 1n }));
        yield* setStorage(addr, slot, valueA);
        const created = yield* getStorage(addr, slot);
        assert.strictEqual(storageValueHex(created), storageValueHex(valueA));

        yield* setStorage(addr, slot, valueB);
        const updated = yield* getStorage(addr, slot);
        assert.strictEqual(storageValueHex(updated), storageValueHex(valueB));

        yield* setStorage(addr, slot, ZERO_STORAGE_VALUE);
        const cleared = yield* getStorage(addr, slot);
        assert.strictEqual(
          storageValueHex(cleared),
          storageValueHex(ZERO_STORAGE_VALUE),
        );
      }),
    ),
  );

  it.effect("restores storage snapshot changes", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(12);
        const slot = makeSlot(2);
        const valueA = makeStorageValue(3);
        const valueB = makeStorageValue(7);

        yield* setAccount(addr, makeAccount({ nonce: 1n }));
        yield* setStorage(addr, slot, valueA);
        const snapshot = yield* takeSnapshot();
        yield* setStorage(addr, slot, valueB);

        yield* restoreSnapshot(snapshot);
        const reverted = yield* getStorage(addr, slot);
        assert.strictEqual(storageValueHex(reverted), storageValueHex(valueA));
      }),
    ),
  );

  it.effect("commits storage snapshot changes", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(13);
        const slot = makeSlot(3);
        const valueA = makeStorageValue(6);
        const valueB = makeStorageValue(8);

        yield* setAccount(addr, makeAccount({ nonce: 1n }));
        yield* setStorage(addr, slot, valueA);
        const snapshot = yield* takeSnapshot();
        yield* setStorage(addr, slot, valueB);

        yield* commitSnapshot(snapshot);
        const committed = yield* getStorage(addr, slot);
        assert.strictEqual(storageValueHex(committed), storageValueHex(valueB));
      }),
    ),
  );

  it.effect("tracks original storage values within a transaction", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(14);
        const slot = makeSlot(4);
        const valueA = makeStorageValue(1);
        const valueB = makeStorageValue(2);

        yield* setAccount(addr, makeAccount({ nonce: 1n }));
        yield* setStorage(addr, slot, valueA);

        const snapshot = yield* takeSnapshot();
        const original = yield* getStorageOriginal(addr, slot);
        assert.strictEqual(storageValueHex(original), storageValueHex(valueA));

        yield* setStorage(addr, slot, valueB);
        const stillOriginal = yield* getStorageOriginal(addr, slot);
        assert.strictEqual(
          storageValueHex(stillOriginal),
          storageValueHex(valueA),
        );

        yield* commitSnapshot(snapshot);
      }),
    ),
  );

  it.effect(
    "preserves original storage after destroyAccount within a snapshot",
    () =>
      provideWorldState(
        Effect.gen(function* () {
          const addr = makeAddress(0x2e);
          const slot = makeSlot(0x06);
          const value = makeStorageValue(0x2a);

          yield* setAccount(addr, makeAccount({ nonce: 1n }));
          yield* setStorage(addr, slot, value);
          yield* takeSnapshot();

          yield* destroyAccount(addr);

          const original = yield* getStorageOriginal(addr, slot);
          assert.strictEqual(storageValueHex(original), storageValueHex(value));
        }),
      ),
  );

  it.effect("returns zero original storage for created accounts", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(15);
        const slot = makeSlot(5);
        const value = makeStorageValue(9);

        const snapshot = yield* takeSnapshot();
        yield* markAccountCreated(addr);
        yield* setAccount(addr, makeAccount({ nonce: 1n }));
        yield* setStorage(addr, slot, value);

        const original = yield* getStorageOriginal(addr, slot);
        assert.strictEqual(
          storageValueHex(original),
          storageValueHex(ZERO_STORAGE_VALUE),
        );

        yield* commitSnapshot(snapshot);
      }),
    ),
  );

  it.effect("restores snapshot changes", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(2);
        yield* setAccount(addr, makeAccount({ nonce: 1n }));

        const snapshot = yield* takeSnapshot();
        yield* setAccount(addr, makeAccount({ nonce: 3n }));

        yield* restoreSnapshot(snapshot);
        const reverted = yield* getAccountOptional(addr);
        assert.strictEqual(reverted?.nonce, 1n);
      }),
    ),
  );

  it.effect("commits snapshot changes", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(3);
        yield* setAccount(addr, makeAccount({ nonce: 4n }));

        const snapshot = yield* takeSnapshot();
        yield* setAccount(addr, makeAccount({ nonce: 5n }));

        yield* commitSnapshot(snapshot);
        const committed = yield* getAccountOptional(addr);
        assert.strictEqual(committed?.nonce, 5n);
      }),
    ),
  );

  it.effect("tracks created accounts within transaction snapshots", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(4);
        const outer = yield* takeSnapshot();
        yield* markAccountCreated(addr);
        yield* setAccount(addr, makeAccount({ nonce: 1n }));

        assert.strictEqual(yield* wasAccountCreated(addr), true);

        const inner = yield* takeSnapshot();
        yield* setAccount(addr, makeAccount({ nonce: 9n }));
        yield* restoreSnapshot(inner);

        assert.strictEqual(yield* wasAccountCreated(addr), true);
        const reverted = yield* getAccountOptional(addr);
        assert.strictEqual(reverted?.nonce, 1n);

        yield* commitSnapshot(outer);
        assert.strictEqual(yield* wasAccountCreated(addr), false);
      }),
    ),
  );

  it.effect("allows explicit markAccountCreated within snapshot", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(5);
        const snapshot = yield* takeSnapshot();

        yield* markAccountCreated(addr);
        assert.strictEqual(yield* wasAccountCreated(addr), true);

        yield* commitSnapshot(snapshot);
        assert.strictEqual(yield* wasAccountCreated(addr), false);
      }),
    ),
  );

  it.effect("fails to set storage for missing accounts", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(6);
        const slot = makeSlot(4);
        const value = makeStorageValue(1);
        const outcome = yield* Effect.either(setStorage(addr, slot, value));
        assert.strictEqual(Either.isLeft(outcome), true);
        if (Either.isLeft(outcome)) {
          assert.strictEqual(outcome.left instanceof MissingAccountError, true);
        }
      }),
    ),
  );

  it.effect("preserves created accounts after snapshot restore", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(7);
        const outer = yield* takeSnapshot();
        const inner = yield* takeSnapshot();

        yield* markAccountCreated(addr);
        yield* setAccount(addr, makeAccount({ nonce: 1n }));
        assert.strictEqual(yield* wasAccountCreated(addr), true);

        yield* restoreSnapshot(inner);
        assert.strictEqual(yield* wasAccountCreated(addr), true);
        const reverted = yield* getAccountOptional(addr);
        assert.strictEqual(reverted, null);

        yield* restoreSnapshot(outer);
        assert.strictEqual(yield* wasAccountCreated(addr), false);
      }),
    ),
  );

  it.effect("fails for unknown snapshots", () =>
    provideWorldState(
      Effect.gen(function* () {
        const outcome = yield* Effect.either(restoreSnapshot(5));
        assert.strictEqual(Either.isLeft(outcome), true);

        if (Either.isLeft(outcome)) {
          assert.strictEqual(outcome.left instanceof UnknownSnapshotError, true);
        }
      }),
    ),
  );

  it.effect("fails to commit unknown snapshots", () =>
    provideWorldState(
      Effect.gen(function* () {
        const outcome = yield* Effect.either(commitSnapshot(5));
        assert.strictEqual(Either.isLeft(outcome), true);

        if (Either.isLeft(outcome)) {
          assert.strictEqual(outcome.left instanceof UnknownSnapshotError, true);
        }
      }),
    ),
  );

  it.effect("clear resets tracked state", () =>
    provideWorldState(
      Effect.gen(function* () {
        const addr = makeAddress(9);
        const slot = makeSlot(9);
        const value = makeStorageValue(7);

        const snapshot = yield* takeSnapshot();
        yield* markAccountCreated(addr);
        yield* setAccount(addr, makeAccount({ nonce: 1n }));
        yield* setStorage(addr, slot, value);

        yield* clear();

        const account = yield* getAccountOptional(addr);
        assert.strictEqual(account, null);

        const stored = yield* getStorage(addr, slot);
        assert.strictEqual(
          storageValueHex(stored),
          storageValueHex(ZERO_STORAGE_VALUE),
        );

        assert.strictEqual(yield* wasAccountCreated(addr), false);

        const restored = yield* Effect.either(restoreSnapshot(snapshot));
        assert.strictEqual(Either.isLeft(restored), true);
        if (Either.isLeft(restored)) {
          assert.strictEqual(restored.left instanceof UnknownSnapshotError, true);
        }
      }),
    ),
  );
});
