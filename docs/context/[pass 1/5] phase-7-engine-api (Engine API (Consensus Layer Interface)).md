# Context - [pass 1/5] phase-7-engine-api (Engine API (Consensus Layer Interface))

## Phase goal
Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

- Phase: `phase-7-engine-api`
- Goal: Implement Engine API for CL <-> EL communication.
- Planned implementation units:
- `client/engine/api.zig` (RPC surface and dispatch)
- `client/engine/payload.zig` (payload build/fetch/validation orchestration)
- Structural references:
- `nethermind/src/Nethermind/Nethermind.Merge.Plugin/`
- `execution-apis/src/engine/`

## Specs to read first (required for implementation)
Sources: `prd/ETHEREUM_SPECS_REFERENCE.md`, `execution-apis/src/engine/*`, `EIPs/EIPS/*`, `execution-specs/src/ethereum/forks/*`

### Engine API core
- `execution-apis/src/engine/README.md`
- `execution-apis/src/engine/common.md`
- `execution-apis/src/engine/authentication.md`
- `execution-apis/src/engine/identification.md`

Key requirements from these files:
- Dedicated authenticated Engine endpoint (default port `8551`, separate from public JSON-RPC).
- JWT auth (`HS256`), reject `alg=none`, include `iat` handling guidance.
- Ordered handling of `engine_forkchoiceUpdated*`.
- Engine-specific error codes `-38001..-38005`.
- `engine_exchangeCapabilities` support on EL side.

### Fork-scoped Engine specs
- `execution-apis/src/engine/paris.md` (`newPayloadV1`, `forkchoiceUpdatedV1`, `getPayloadV1`, transition config)
- `execution-apis/src/engine/shanghai.md` (`newPayloadV2`, `forkchoiceUpdatedV2`, `getPayloadV2`, payload bodies APIs)
- `execution-apis/src/engine/cancun.md` (`newPayloadV3`, `forkchoiceUpdatedV3`, `getPayloadV3`, `getBlobsV1`)
- `execution-apis/src/engine/prague.md` (`newPayloadV4`, `getPayloadV4`, `executionRequests`)
- `execution-apis/src/engine/osaka.md` (`getPayloadV5`, blob proof model updates, `getBlobsV2`/`getBlobsV3`)
- `execution-apis/src/engine/amsterdam.md` (`newPayloadV5`, `getPayloadV6`, `forkchoiceUpdatedV4`, payload bodies v2)

OpenRPC contracts:
- `execution-apis/src/engine/openrpc/methods/payload.yaml`
- `execution-apis/src/engine/openrpc/methods/forkchoice.yaml`
- `execution-apis/src/engine/openrpc/methods/blob.yaml`
- `execution-apis/src/engine/openrpc/methods/capabilities.yaml`
- `execution-apis/src/engine/openrpc/methods/transition_configuration.yaml`

### EIPs directly tied to phase-7 behavior
- `EIPs/EIPS/eip-3675.md` (The Merge, terminal PoW/PoS transition assumptions)
- `EIPs/EIPS/eip-4399.md` (`PREVRANDAO`)
- `EIPs/EIPS/eip-4895.md` (withdrawals in payload/header)
- `EIPs/EIPS/eip-4844.md` (blob tx and blob gas fields)
- `EIPs/EIPS/eip-4788.md` (`parentBeaconBlockRoot`)
- `EIPs/EIPS/eip-7685.md` (EL-triggered request commitment model)
- `EIPs/EIPS/eip-6110.md` (deposit requests)
- `EIPs/EIPS/eip-7002.md` (withdrawal requests)
- `EIPs/EIPS/eip-7251.md` (consolidation requests)

### execution-specs fork files for validation behavior
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
Key files:
- `IDb.cs`, `IReadOnlyDb.cs`, `IDbProvider.cs`, `IReadOnlyDbProvider.cs`, `IDbFactory.cs`
- `DbProvider.cs`, `DbProviderExtensions.cs`, `ReadOnlyDbProvider.cs`
- `IColumnsDb.cs`, `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`
- `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `ReadOnlyColumnsDb.cs`, `CompressingDb.cs`
- `DbNames.cs`, `MetadataDbKeys.cs`, `DbExtensions.cs`, `Metrics.cs`
- `IPruningConfig.cs`, `PruningConfig.cs`, `PruningMode.cs`, `FullPruning/`

### Engine architecture reference: `nethermind/src/Nethermind/Nethermind.Merge.Plugin/`
Key files:
- `EngineRpcModule.cs`, `EngineRpcModule.Paris.cs`, `EngineRpcModule.Shanghai.cs`, `EngineRpcModule.Cancun.cs`, `EngineRpcModule.Prague.cs`, `EngineRpcModule.Osaka.cs`
- `IEngineRpcModule.cs` and fork-specific interface files
- `Handlers/` (method-specific handler split for payload/forkchoice/blobs/capabilities/transition config)
- `Data/` (typed payload/forkchoice/result DTOs)
- `MergeErrorCodes.cs`, `MergeErrorMessages.cs`

## Voltaire APIs to use (no custom duplicate types)
Base path: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

Core exports:
- `root.zig` (`Primitives`, `Crypto`)
- `primitives/root.zig`
- `jsonrpc/root.zig`
- `jsonrpc/JsonRpc.zig`
- `jsonrpc/types.zig`

Engine namespace types/methods:
- `jsonrpc/engine/methods.zig` (`EngineMethod` tagged union, method-name mapping)
- `jsonrpc/engine/newPayloadV1/engine_newPayloadV1.zig`
- `jsonrpc/engine/newPayloadV2/engine_newPayloadV2.zig`
- `jsonrpc/engine/newPayloadV3/engine_newPayloadV3.zig`
- `jsonrpc/engine/newPayloadV4/engine_newPayloadV4.zig`
- `jsonrpc/engine/newPayloadV5/engine_newPayloadV5.zig`
- `jsonrpc/engine/forkchoiceUpdatedV1/engine_forkchoiceUpdatedV1.zig`
- `jsonrpc/engine/forkchoiceUpdatedV2/engine_forkchoiceUpdatedV2.zig`
- `jsonrpc/engine/forkchoiceUpdatedV3/engine_forkchoiceUpdatedV3.zig`
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
- `jsonrpc/engine/exchangeCapabilities/engine_exchangeCapabilities.zig`
- `jsonrpc/engine/exchangeTransitionConfigurationV1/engine_exchangeTransitionConfigurationV1.zig`

Relevant primitive exports (use these, do not duplicate):
- `primitives.Block`, `primitives.BlockHeader`, `primitives.BlockHash`
- `primitives.BeaconBlockRoot`, `primitives.Withdrawal`
- `primitives.Address`, `primitives.Hash`, `primitives.Bytes32`
- `primitives.Uint`, `primitives.Rlp`

## Existing Zig host boundary
- Requested path `src/host.zig` is not present at repository root.
- Resolved file: `guillotine-mini/src/host.zig`.
- `HostInterface` is a vtable DI surface (`ptr` + `VTable`) with:
- `getBalance`, `setBalance`
- `getCode`, `setCode`
- `getStorage`, `setStorage`
- `getNonce`, `setNonce`
- File note: nested EVM calls are handled in EVM internals, not via this host abstraction.

## Test fixture paths

### Required listing from `ethereum-tests/`
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

### Engine-related harness/fixtures
- `hive/simulators/eth2/engine/`
- `hive/simulators/ethereum/engine/`
- `execution-spec-tests/src/pytest_plugins/consume/hive_engine_test/`
- `execution-spec-tests/src/pytest_plugins/consume/simulators/engine/`
- `execution-spec-tests/fixtures/`

Path note:
- `prd/ETHEREUM_SPECS_REFERENCE.md` points to `execution-spec-tests/fixtures/blockchain_tests_engine/`.
- In this workspace, `execution-spec-tests/fixtures/` exists, but `blockchain_tests_engine/` is not currently present.

## Phase-7 implementation guardrails
- Use Voltaire JSON-RPC and primitives types as canonical request/response carriers.
- Reuse existing `guillotine-mini` EVM integration points; do not reimplement execution logic.
- Mirror Nethermind's module split conceptually, but use Zig idioms and comptime DI.
- Enforce Engine API fork/version rules exactly (params, response shape, and error codes).
