import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Either from "effect/Either";
import * as Layer from "effect/Layer";
import { JsonRpcErrorRegistryLive } from "./JsonRpcErrors";
import {
  encodeJsonRpcErrorByName,
  encodeJsonRpcResponse,
  InvalidJsonRpcResponseError,
  JsonRpcResponse,
  JsonRpcResponseEncoderLive,
  type JsonRpcResponseSuccess,
} from "./JsonRpcResponse";

const TestLayer = JsonRpcResponseEncoderLive.pipe(
  Layer.provide(JsonRpcErrorRegistryLive),
);

const provideEncoder = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
  effect.pipe(Effect.provide(TestLayer));

describe("JsonRpcResponse", () => {
  it.effect("encodes success responses", () =>
    provideEncoder(
      Effect.gen(function* () {
        const response = {
          jsonrpc: "2.0",
          id: 1,
          result: "0x1",
        } satisfies JsonRpcResponseSuccess<string>;

        const encoded = yield* encodeJsonRpcResponse(response);

        assert.deepStrictEqual(encoded, response);
      }),
    ),
  );

  it.effect("encodes success responses with null ids", () =>
    provideEncoder(
      Effect.gen(function* () {
        const response = {
          jsonrpc: "2.0",
          id: null,
          result: "0x1",
        } satisfies JsonRpcResponseSuccess<string>;

        const encoded = yield* encodeJsonRpcResponse(response);

        assert.deepStrictEqual(encoded, response);
      }),
    ),
  );

  it.effect("encodes EIP-1474 error responses by name", () =>
    provideEncoder(
      Effect.gen(function* () {
        const encoded = yield* encodeJsonRpcErrorByName(
          "EIP-1474",
          "InvalidRequest",
          null,
          { reason: "bad payload" },
        );

        assert.strictEqual(encoded.jsonrpc, "2.0");
        assert.deepStrictEqual(encoded.error, {
          code: -32600,
          message: "Invalid request",
          data: { reason: "bad payload" },
        });
        assert.strictEqual(encoded.id, null);
      }),
    ),
  );

  it.effect("rejects invalid response payloads", () =>
    provideEncoder(
      Effect.gen(function* () {
        const invalid = {
          jsonrpc: "2.1",
          result: "0x1",
          id: 1,
        } as JsonRpcResponse;

        const outcome = yield* Effect.either(encodeJsonRpcResponse(invalid));

        assert.strictEqual(Either.isLeft(outcome), true);
        if (Either.isLeft(outcome)) {
          assert.strictEqual(outcome.left instanceof InvalidJsonRpcResponseError, true);
        }
      }),
    ),
  );

  it.effect("rejects non-JSON result payloads", () =>
    provideEncoder(
      Effect.gen(function* () {
        const invalid = {
          jsonrpc: "2.0",
          result: 1n,
          id: 1,
        } as JsonRpcResponse;

        const outcome = yield* Effect.either(encodeJsonRpcResponse(invalid));

        assert.strictEqual(Either.isLeft(outcome), true);
        if (Either.isLeft(outcome)) {
          assert.strictEqual(outcome.left instanceof InvalidJsonRpcResponseError, true);
        }
      }),
    ),
  );

  it.effect("rejects non-integer error codes", () =>
    provideEncoder(
      Effect.gen(function* () {
        const invalid = {
          jsonrpc: "2.0",
          error: {
            code: 1.5,
            message: "nope",
          },
          id: 1,
        } as JsonRpcResponse;

        const outcome = yield* Effect.either(encodeJsonRpcResponse(invalid));

        assert.strictEqual(Either.isLeft(outcome), true);
        if (Either.isLeft(outcome)) {
          assert.strictEqual(outcome.left instanceof InvalidJsonRpcResponseError, true);
        }
      }),
    ),
  );
});
