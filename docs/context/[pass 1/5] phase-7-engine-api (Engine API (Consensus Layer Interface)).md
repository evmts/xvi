# Context — [pass 1/5] phase-7-engine-api (Engine API (Consensus Layer Interface))

## Phase Goal (from `prd/GUILLOTINE_CLIENT_PLAN.md`)
- Phase: `phase-7-engine-api`
- Goal: Implement the Engine API for consensus-layer communication.
- Planned units:
  - `client/engine/api.zig` (Engine API surface + dispatch)
  - `client/engine/payload.zig` (payload build/retrieval + validation orchestration)
- Primary structural references:
  - `nethermind/src/Nethermind/Nethermind.Merge.Plugin/`
  - `execution-apis/src/engine/`

## Relevant Specs (from `prd/ETHEREUM_SPECS_REFERENCE.md` + direct reads)

### Engine API specs (authoritative wire behavior)
- `execution-apis/src/engine/common.md`
  - Dedicated authenticated Engine endpoint (default port `8551`), ordering constraints for `engine_forkchoiceUpdated*`, Engine error code set (`-38001..-38005`), capabilities exchange.
- `execution-apis/src/engine/authentication.md`
  - JWT/`HS256` requirement, `jwt-secret` file handling, `iat` tolerance guidance (`+-60s`).
- `execution-apis/src/engine/identification.md`
  - `engine_getClientVersionV1` + `ClientVersionV1`/`ClientCode` conventions.
- Fork-scoped method/version specs:
  - `execution-apis/src/engine/paris.md` (V1 baseline)
  - `execution-apis/src/engine/shanghai.md` (V2 + withdrawals + payload bodies methods)
  - `execution-apis/src/engine/cancun.md` (V3 + blobs + `engine_getBlobsV1`)
  - `execution-apis/src/engine/prague.md` (V4 + `executionRequests`)
  - `execution-apis/src/engine/osaka.md` (V5 payload retrieval semantics + blob method evolution)
  - `execution-apis/src/engine/amsterdam.md` (V5 `newPayload`, V6 `getPayload`, forkchoice V4, payload bodies V2)
- OpenRPC method/schema sources:
  - `execution-apis/src/engine/openrpc/methods/*.yaml`
  - `execution-apis/src/engine/openrpc/schemas/*.yaml`

### EIPs relevant to Engine API payload/forkchoice validation
- `EIPs/EIPS/eip-3675.md`
  - Merge transition, terminal block conditions, PoS forkchoice update mapping.
- `EIPs/EIPS/eip-4399.md`
  - `PREVRANDAO` semantics and block field/opcode transition.
- `EIPs/EIPS/eip-4895.md`
  - Withdrawals in payload/header and withdrawal-root validation.
- `EIPs/EIPS/eip-4844.md`
  - Blob tx semantics, blob gas fields, versioned hash constraints.
- `EIPs/EIPS/eip-4788.md`
  - `parent_beacon_block_root` header semantics/system handling.
- `EIPs/EIPS/eip-7685.md`
  - `requests_hash` commitment format and request ordering model.
- `EIPs/EIPS/eip-6110.md`
  - Deposit requests carried through EL block processing model.
- `EIPs/EIPS/eip-7002.md`
  - Withdrawal request system contract + EIP-7685 request typing.
- `EIPs/EIPS/eip-7251.md`
  - Consolidation requests (EIP-7685 request type `0x02`).

### execution-specs files to anchor validation/state-transition behavior
- `execution-specs/src/ethereum/forks/paris/fork.py`
- `execution-specs/src/ethereum/forks/paris/blocks.py`
- `execution-specs/src/ethereum/forks/shanghai/fork.py`
- `execution-specs/src/ethereum/forks/shanghai/blocks.py`
- `execution-specs/src/ethereum/forks/cancun/fork.py`
- `execution-specs/src/ethereum/forks/cancun/blocks.py`
- `execution-specs/src/ethereum/forks/prague/fork.py`
- `execution-specs/src/ethereum/forks/prague/blocks.py`
- `execution-specs/src/ethereum/forks/prague/requests.py`
- `execution-specs/src/ethereum/forks/osaka/fork.py`
- `execution-specs/src/ethereum/forks/osaka/blocks.py`
- `execution-specs/src/ethereum/forks/osaka/requests.py`

## Nethermind reference inventory

### Required listing: `nethermind/src/Nethermind/Nethermind.Db/`
Key files noted:
- Interfaces/providers:
  - `IDb.cs`, `IReadOnlyDb.cs`, `IDbProvider.cs`, `IReadOnlyDbProvider.cs`, `IDbFactory.cs`, `DbProvider.cs`, `ReadOnlyDbProvider.cs`
- Implementations:
  - `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `ReadOnlyColumnsDb.cs`, `CompressingDb.cs`
- Write batching/columns:
  - `IColumnsDb.cs`, `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`
- Configuration/pruning:
  - `IPruningConfig.cs`, `PruningConfig.cs`, `PruningMode.cs`, `FullPruning/*`
- Metadata/ops:
  - `DbNames.cs`, `MetadataDbKeys.cs`, `DbExtensions.cs`, `Metrics.cs`

### Phase-7 architecture reference: `nethermind/src/Nethermind/Nethermind.Merge.Plugin/`
Key files noted:
- Module surfaces:
  - `EngineRpcModule.cs`
  - `EngineRpcModule.Paris.cs`, `EngineRpcModule.Shanghai.cs`, `EngineRpcModule.Cancun.cs`, `EngineRpcModule.Prague.cs`, `EngineRpcModule.Osaka.cs`
- Handlers:
  - `Handlers/NewPayloadHandler.cs`
  - `Handlers/ForkchoiceUpdatedHandler.cs`
  - `Handlers/GetPayloadV1Handler.cs` ... `Handlers/GetPayloadV5Handler.cs`
  - `Handlers/GetPayloadBodiesByHashV1Handler.cs`
  - `Handlers/GetPayloadBodiesByRangeV1Handler.cs`
  - `Handlers/GetBlobsHandler.cs`, `Handlers/GetBlobsHandlerV2.cs`
  - `Handlers/ExchangeCapabilitiesHandler.cs`
  - `Handlers/ExchangeTransitionConfigurationV1Handler.cs`
- Data contracts:
  - `Data/ExecutionPayload.cs`, `Data/ExecutionPayloadV3.cs`
  - `Data/ForkchoiceStateV1.cs`, `Data/PayloadStatusV1.cs`
  - `Data/TransitionConfigurationV1.cs`
  - `Data/GetPayloadV2Result.cs` ... `Data/GetPayloadV5Result.cs`

## Voltaire APIs to use (no custom duplicate types)
Base path: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

### Core module roots
- `root.zig`
- `primitives/root.zig`
- `jsonrpc/root.zig`
- `jsonrpc/JsonRpc.zig`
- `jsonrpc/types.zig`

### Engine JSON-RPC method surfaces
- `jsonrpc/engine/methods.zig`
- Versioned method modules:
  - `jsonrpc/engine/exchangeCapabilities/engine_exchangeCapabilities.zig`
  - `jsonrpc/engine/exchangeTransitionConfigurationV1/engine_exchangeTransitionConfigurationV1.zig`
  - `jsonrpc/engine/forkchoiceUpdatedV1/engine_forkchoiceUpdatedV1.zig`
  - `jsonrpc/engine/forkchoiceUpdatedV2/engine_forkchoiceUpdatedV2.zig`
  - `jsonrpc/engine/forkchoiceUpdatedV3/engine_forkchoiceUpdatedV3.zig`
  - `jsonrpc/engine/newPayloadV1/engine_newPayloadV1.zig`
  - `jsonrpc/engine/newPayloadV2/engine_newPayloadV2.zig`
  - `jsonrpc/engine/newPayloadV3/engine_newPayloadV3.zig`
  - `jsonrpc/engine/newPayloadV4/engine_newPayloadV4.zig`
  - `jsonrpc/engine/newPayloadV5/engine_newPayloadV5.zig`
  - `jsonrpc/engine/getPayloadV1/engine_getPayloadV1.zig`
  - `jsonrpc/engine/getPayloadV2/engine_getPayloadV2.zig`
  - `jsonrpc/engine/getPayloadV3/engine_getPayloadV3.zig`
  - `jsonrpc/engine/getPayloadV4/engine_getPayloadV4.zig`
  - `jsonrpc/engine/getPayloadV5/engine_getPayloadV5.zig`
  - `jsonrpc/engine/getPayloadV6/engine_getPayloadV6.zig`
  - `jsonrpc/engine/getPayloadBodiesByHashV1/engine_getPayloadBodiesByHashV1.zig`
  - `jsonrpc/engine/getPayloadBodiesByRangeV1/engine_getPayloadBodiesByRangeV1.zig`
  - `jsonrpc/engine/getBlobsV1/engine_getBlobsV1.zig`
  - `jsonrpc/engine/getBlobsV2/engine_getBlobsV2.zig`

### Primitive types likely needed by Engine API orchestration
- `primitives.Block`
- `primitives.BlockHeader`
- `primitives.BlockHash`
- `primitives.Hash`
- `primitives.Withdrawal`
- `primitives.Address`
- `primitives.Uint`
- `primitives.Bytes32`
- `primitives.BloomFilter`
- `primitives.Rlp`

## Existing Zig host boundary
- Requested path `src/host.zig` does not exist at repository root.
- Resolved host interface path: `guillotine-mini/src/host.zig`.
- `HostInterface` is a vtable DI boundary (`ptr` + `VTable`) with methods:
  - `getBalance`/`setBalance`
  - `getCode`/`setCode`
  - `getStorage`/`setStorage`
  - `getNonce`/`setNonce`
- File-level note states nested EVM calls are handled internally by guillotine-mini and not routed through this host interface.

## Test fixtures and harness paths

### Required listing: `ethereum-tests/` directories
Key fixture roots:
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/EOFTests/`
- `ethereum-tests/GenesisTests/`
- `ethereum-tests/DifficultyTests/`
- `ethereum-tests/RLPTests/`
- `ethereum-tests/ABITests/`
- `ethereum-tests/PoWTests/`

### Engine-relevant external harness paths
- `hive/simulators/eth2/engine/`
- `hive/simulators/ethereum/engine/`
- `execution-spec-tests/src/pytest_plugins/consume/hive_engine_test/`
- `execution-spec-tests/src/ethereum_test_fixtures/tests/`

### Spec-reference path check
- `prd/ETHEREUM_SPECS_REFERENCE.md` mentions `execution-spec-tests/fixtures/blockchain_tests_engine/`.
- In this workspace, `execution-spec-tests/fixtures/` exists but currently has no populated subdirectories.

## Implementation constraints derived from context
- Use Voltaire JSON-RPC/primitive types as canonical request/response/data carriers; avoid duplicate custom DTOs.
- Implement versioned Engine methods with comptime dispatch/DI patterns similar to existing guillotine-mini style.
- Keep strict spec behavior per fork/version (`Unsupported fork`, payload structure gating, and error-code semantics).
- Use Nethermind handler/module split only as architecture reference; implement idiomatically in Zig.
- Preserve EVM boundary: orchestrate through existing guillotine-mini execution path, do not reimplement EVM internals.
