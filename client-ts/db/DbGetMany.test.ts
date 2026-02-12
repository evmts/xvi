import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import { Bytes } from "voltaire-effect/primitives";
import { DbMemoryTest, DbNullTest, getMany, put } from "./Db";
import { toBytes } from "./testUtils";

describe("Db getMany", () => {
  it.effect("returns values in input order with none for missing keys", () =>
    Effect.gen(function* () {
      const keyA = toBytes("0x10");
      const keyB = toBytes("0x11");
      const keyC = toBytes("0x12");
      const valueA = toBytes("0xaa");
      const valueC = toBytes("0xcc");

      yield* put(keyA, valueA);
      yield* put(keyC, valueC);

      const entries = yield* getMany([keyA, keyB, keyC]);
      assert.strictEqual(entries.length, 3);
      const first = entries[0]!;
      const second = entries[1]!;
      const third = entries[2]!;
      assert.strictEqual(Bytes.equals(first.key, keyA), true);
      assert.strictEqual(Option.isSome(first.value), true);
      assert.strictEqual(Bytes.equals(Option.getOrThrow(first.value), valueA), true);
      assert.strictEqual(Bytes.equals(second.key, keyB), true);
      assert.strictEqual(Option.isNone(second.value), true);
      assert.strictEqual(Bytes.equals(third.key, keyC), true);
      assert.strictEqual(Option.isSome(third.value), true);
      assert.strictEqual(Bytes.equals(Option.getOrThrow(third.value), valueC), true);
    }).pipe(Effect.provide(DbMemoryTest())),
  );

  it.effect("returns none for all keys in NullDb", () =>
    Effect.gen(function* () {
      const keyA = toBytes("0x20");
      const keyB = toBytes("0x21");

      const entries = yield* getMany([keyA, keyB]);
      assert.strictEqual(entries.length, 2);
      const first = entries[0]!;
      const second = entries[1]!;
      assert.strictEqual(Bytes.equals(first.key, keyA), true);
      assert.strictEqual(Option.isNone(first.value), true);
      assert.strictEqual(Bytes.equals(second.key, keyB), true);
      assert.strictEqual(Option.isNone(second.value), true);
    }).pipe(Effect.provide(DbNullTest())),
  );
});
