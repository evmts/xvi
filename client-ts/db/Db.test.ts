import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import { Bytes } from "voltaire-effect/primitives";
import {
  DbMemoryTest,
  gatherMetric,
  get,
  getAllKeys,
  has,
  put,
  remove,
} from "./Db";
import { toBytes } from "./testUtils";

describe("Db", () => {
  it.effect("put/get round-trips bytes", () =>
    Effect.gen(function* () {
      const key = toBytes("0x01");
      const value = toBytes("0xdeadbeef");

      yield* put(key, value);
      const result = yield* get(key);

      const stored = Option.getOrThrow(result);
      assert.strictEqual(Bytes.equals(stored, value), true);
    }).pipe(Effect.provide(DbMemoryTest())),
  );

  it.effect("get returns none for missing keys", () =>
    Effect.gen(function* () {
      const key = toBytes("0x02");
      const result = yield* get(key);
      assert.strictEqual(Option.isNone(result), true);
    }).pipe(Effect.provide(DbMemoryTest())),
  );

  it.effect("has reflects put/remove", () =>
    Effect.gen(function* () {
      const key = toBytes("0x03");
      const value = toBytes("0x01");

      assert.strictEqual(yield* has(key), false);
      yield* put(key, value);
      assert.strictEqual(yield* has(key), true);
      yield* remove(key);
      assert.strictEqual(yield* has(key), false);
    }).pipe(Effect.provide(DbMemoryTest())),
  );

  it.effect("remove deletes stored values", () =>
    Effect.gen(function* () {
      const key = toBytes("0x04");
      const value = toBytes("0x1234");

      yield* put(key, value);
      yield* remove(key);
      const result = yield* get(key);
      assert.strictEqual(Option.isNone(result), true);
    }).pipe(Effect.provide(DbMemoryTest())),
  );

  it.effect("getAllKeys(ordered) uses Nethermind byte ordering", () =>
    Effect.gen(function* () {
      const shortKey = toBytes("0x01");
      const longKey = toBytes("0x0100");

      yield* put(shortKey, toBytes("0x11"));
      yield* put(longKey, toBytes("0x22"));

      const keys = yield* getAllKeys(true);
      assert.strictEqual(keys.length, 2);
      assert.strictEqual(Bytes.equals(keys[0]!, longKey), true);
      assert.strictEqual(Bytes.equals(keys[1]!, shortKey), true);
    }).pipe(Effect.provide(DbMemoryTest())),
  );

  it.effect("gatherMetric tracks reads and writes", () =>
    Effect.gen(function* () {
      const key = toBytes("0x05");
      const value = toBytes("0xaaaa");

      yield* put(key, value);
      yield* get(key);

      const metrics = yield* gatherMetric();
      assert.deepStrictEqual(metrics, {
        size: 1,
        cacheSize: 0,
        indexSize: 0,
        memtableSize: 0,
        totalReads: 1,
        totalWrites: 1,
      });
    }).pipe(Effect.provide(DbMemoryTest())),
  );
});
