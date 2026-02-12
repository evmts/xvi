import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import {
  EMPTY_ACCOUNT,
  hasCodeOrNonce,
  isAccountAlive,
  isContract,
  isEmpty,
  isTotallyEmpty,
  makeAccount,
  type AccountStateType,
} from "./Account";

const customBytes32 = (byte: number): AccountStateType["codeHash"] => {
  const value = new Uint8Array(32);
  value.fill(byte);
  return value as AccountStateType["codeHash"];
};

describe("Account helpers", () => {
  it.effect("makeAccount constructs default empty accounts", () =>
    Effect.gen(function* () {
      const account = makeAccount();
      assert.strictEqual(account.nonce, 0n);
      assert.strictEqual(account.balance, 0n);
      assert.strictEqual(isTotallyEmpty(account), true);
    }),
  );

  it.effect("makeAccount applies overrides", () =>
    Effect.gen(function* () {
      const account = makeAccount({ nonce: 9n, balance: 42n });
      assert.strictEqual(account.nonce, 9n);
      assert.strictEqual(account.balance, 42n);
    }),
  );

  it.effect("makeAccount clones byte-array overrides", () =>
    Effect.gen(function* () {
      const codeHash = customBytes32(0x11);
      const account = makeAccount({ codeHash });
      codeHash[0] = 0x22;

      assert.notStrictEqual(account.codeHash[0], codeHash[0]);
    }),
  );

  it.effect("treats EMPTY_ACCOUNT as empty, totally empty, and not alive", () =>
    Effect.gen(function* () {
      assert.strictEqual(isEmpty(EMPTY_ACCOUNT), true);
      assert.strictEqual(isTotallyEmpty(EMPTY_ACCOUNT), true);
      assert.strictEqual(isAccountAlive(EMPTY_ACCOUNT), false);
      assert.strictEqual(hasCodeOrNonce(EMPTY_ACCOUNT), false);
    }),
  );

  it.effect("detects non-empty accounts as alive", () =>
    Effect.gen(function* () {
      const account = makeAccount({ nonce: 1n });
      assert.strictEqual(isAccountAlive(account), true);
    }),
  );

  it.effect("treats storage root as irrelevant for emptiness", () =>
    Effect.gen(function* () {
      const account = makeAccount({ storageRoot: customBytes32(0xab) });
      assert.strictEqual(isEmpty(account), true);
      assert.strictEqual(isTotallyEmpty(account), false);
    }),
  );

  it.effect("detects code hash for hasCodeOrNonce", () =>
    Effect.gen(function* () {
      const account = makeAccount({ codeHash: customBytes32(0xcd) });
      assert.strictEqual(hasCodeOrNonce(account), true);
    }),
  );

  it.effect("detects contracts by code hash", () =>
    Effect.gen(function* () {
      assert.strictEqual(isContract(EMPTY_ACCOUNT), false);
      const account = makeAccount({ codeHash: customBytes32(0xaa) });
      assert.strictEqual(isContract(account), true);
    }),
  );

  it.effect("ignores balance-only for hasCodeOrNonce", () =>
    Effect.gen(function* () {
      const account = makeAccount({ balance: 1_000_000n });
      assert.strictEqual(hasCodeOrNonce(account), false);
      assert.strictEqual(isEmpty(account), false);
    }),
  );
});
