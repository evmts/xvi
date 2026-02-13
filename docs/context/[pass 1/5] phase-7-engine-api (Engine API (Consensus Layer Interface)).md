# Context — [pass 1/5] phase-7-engine-api (Engine API (Consensus Layer Interface))

## Phase Goal (from `prd/GUILLOTINE_CLIENT_PLAN.md`)
- Implement Engine API for Consensus Layer communication.
- Planned units:
  - `client/engine/api.zig` (method dispatch/validation)
  - `client/engine/payload.zig` (payload building + retrieval)
- Structural references:
  - `nethermind/src/Nethermind/Nethermind.Merge.Plugin/`
  - `execution-apis/src/engine/`

## Relevant Specs (from `prd/ETHEREUM_SPECS_REFERENCE.md` + direct reads)

### Primary Engine API specs
- `execution-apis/src/engine/common.md`
  - Authenticated Engine API on dedicated port (default `8551`), strict error code set (`-38001..-38005`), ordering requirement for `engine_forkchoiceUpdated*`, and capability negotiation via `engine_exchangeCapabilities`.
- `execution-apis/src/engine/authentication.md`
  - JWT (`HS256`) requirement, `jwt-secret` handling, `iat` skew guidance (`+-60s`).
- `execution-apis/src/engine/paris.md`
  - Baseline methods: `engine_newPayloadV1`, `engine_forkchoiceUpdatedV1`, `engine_getPayloadV1`, `engine_exchangeTransitionConfigurationV1`.
  - Canonical `PayloadStatusV1` semantics (`VALID`, `INVALID`, `SYNCING`, `ACCEPTED`, `INVALID_BLOCK_HASH`).
- `execution-apis/src/engine/shanghai.md`
  - Introduces payload V2 + withdrawals, forkchoice V2, payload bodies by hash/range V1.
- `execution-apis/src/engine/cancun.md`
  - Introduces payload V3 + blob fields, forkchoice V3, `engine_getBlobsV1`, transition-config deprecation behavior.
- `execution-apis/src/engine/prague.md`
  - Introduces `engine_newPayloadV4` and `engine_getPayloadV4` with `executionRequests`.
- `execution-apis/src/engine/osaka.md`
  - Introduces `engine_getPayloadV5`, `engine_getBlobsV2`, `engine_getBlobsV3` semantics.
- `execution-apis/src/engine/amsterdam.md`
  - Introduces `engine_newPayloadV5`, `engine_getPayloadV6`, payload bodies V2, forkchoice V4, payload attributes V4.
- OpenRPC detail files used for method inventories:
  - `execution-apis/src/engine/openrpc/methods/forkchoice.yaml`
  - `execution-apis/src/engine/openrpc/methods/payload.yaml`
  - `execution-apis/src/engine/openrpc/methods/blob.yaml`
  - `execution-apis/src/engine/openrpc/methods/capabilities.yaml`
  - `execution-apis/src/engine/openrpc/methods/transition_configuration.yaml`

### EIPs directly relevant to Engine API behavior
- `EIPs/EIPS/eip-3675.md` (Merge: terminal block validity, PoS forkchoice event mapping, block field constraints).
- `EIPs/EIPS/eip-4399.md` (`PREVRANDAO` semantics replacing `DIFFICULTY`).
- `EIPs/EIPS/eip-4895.md` (withdrawals in payload/header).
- `EIPs/EIPS/eip-4844.md` (blob tx fields, blob gas header rules, KZG-related payload constraints).
- `EIPs/EIPS/eip-7685.md` (`requests_hash` and execution requests commitment rules).
- Also present for future fork alignment: `EIPs/EIPS/eip-4788.md`, `EIPs/EIPS/eip-2935.md`.

### Execution-specs files to use for payload/header validation logic
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
- `execution-specs/src/ethereum/genesis.py` (fork-aware header field initialization).

## Nethermind reference inventory

### Requested DB folder listing (`nethermind/src/Nethermind/Nethermind.Db/`)
Key files to mirror for boundary design (idiomatic Zig + comptime DI):
- Interfaces/providers: `IDb.cs`, `IDbProvider.cs`, `DbProvider.cs`, `ReadOnlyDbProvider.cs`, `IDbFactory.cs`.
- DB forms: `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `CompressingDb.cs`.
- Batching/columns: `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`, `IColumnsDb.cs`.
- Pruning/config: `IPruningConfig.cs`, `PruningConfig.cs`, `PruningMode.cs`, `FullPruning/*`.
- Metadata/utilities: `DbNames.cs`, `MetadataDbKeys.cs`, `DbExtensions.cs`, `Metrics.cs`.

### Engine-specific Nethermind structure to mirror
- Main module + versioned RPC surfaces:
  - `nethermind/src/Nethermind/Nethermind.Merge.Plugin/EngineRpcModule.cs`
  - `.../EngineRpcModule.Paris.cs`
  - `.../EngineRpcModule.Shanghai.cs`
  - `.../EngineRpcModule.Cancun.cs`
  - `.../EngineRpcModule.Prague.cs`
  - `.../EngineRpcModule.Osaka.cs`
- Handler split:
  - `.../Handlers/NewPayloadHandler.cs`
  - `.../Handlers/ForkchoiceUpdatedHandler.cs`
  - `.../Handlers/GetPayloadV1Handler.cs` through `GetPayloadV5Handler.cs`
  - `.../Handlers/GetPayloadBodiesByHashV1Handler.cs`
  - `.../Handlers/GetPayloadBodiesByRangeV1Handler.cs`
  - `.../Handlers/GetBlobsHandler.cs`, `GetBlobsHandlerV2.cs`
  - `.../Handlers/ExchangeCapabilitiesHandler.cs`
- Data contracts:
  - `.../Data/ExecutionPayload*.cs`
  - `.../Data/PayloadStatusV1.cs`
  - `.../Data/ForkchoiceStateV1.cs`
  - `.../Data/TransitionConfigurationV1.cs`

## Voltaire Zig APIs to use (no custom duplicate types)
Base path: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

### JSON-RPC + Engine method types
- `jsonrpc/root.zig`
- `jsonrpc/JsonRpc.zig`
- `jsonrpc/engine/methods.zig`
- `jsonrpc/engine/**/engine_*.zig`
  - Available now: exchangeCapabilities, exchangeTransitionConfigurationV1, forkchoiceUpdatedV1..V3, newPayloadV1..V5, getPayloadV1..V6, getPayloadBodiesByHashV1, getPayloadBodiesByRangeV1, getBlobsV1..V2.

### Shared JSON-RPC value types
- `jsonrpc/types.zig`
- `jsonrpc/types/Address.zig`
- `jsonrpc/types/Hash.zig`
- `jsonrpc/types/Quantity.zig`
- `jsonrpc/types/BlockTag.zig`
- `jsonrpc/types/BlockSpec.zig`

### Core primitives (payload fields, hashes, headers, fees, withdrawals, blobs)
- `primitives/root.zig`
- Important exports used by Engine API payload handling:
  - `primitives.Block`
  - `primitives.BlockHeader`
  - `primitives.BlockHash`
  - `primitives.Hash`
  - `primitives.Withdrawal`
  - `primitives.Blob`
  - `primitives.ForkTransition`
  - `primitives.Hardfork`
  - `primitives.Address`
  - `primitives.Uint` and fixed-width wrappers

## Existing EVM host boundary
- Requested file `src/host.zig` is not present in this repo root.
- Actual host interface file: `guillotine-mini/src/host.zig`.
- `HostInterface` is a vtable-based external state bridge with:
  - `get/setBalance`
  - `get/setCode`
  - `get/setStorage`
  - `get/setNonce`
- Nested call execution is handled internally by guillotine-mini EVM; Engine API integration should orchestrate state/payload flow around this boundary, not replace EVM internals.

## Test fixtures and directories

### ethereum-tests (requested listing)
Primary fixture roots:
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/EOFTests/`
- `ethereum-tests/GenesisTests/`
- `ethereum-tests/DifficultyTests/`
- `ethereum-tests/RLPTests/`
- Notable Engine-adjacent coverage directories:
  - `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP3675`
  - `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP3675`
  - `ethereum-tests/BlockchainTests/InvalidBlocks/bc4895-withdrawals`
  - `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP4844-blobtransactions`

### Additional Engine API harnesses referenced by PRD/spec reference
- `hive/simulators/eth2/engine/`
- `hive/simulators/ethereum/engine/`
- `execution-spec-tests/fixtures/`

## Immediate implementation guidance for Phase 7
- Use Voltaire `jsonrpc.engine` method structs as canonical request/response contracts.
- Build versioned handler dispatch via comptime mapping (do not hand-roll duplicate DTOs).
- Keep component boundaries:
  - transport/auth (`JWT`, port separation)
  - engine method dispatcher
  - forkchoice/payload orchestrator
  - guillotine-mini execution path
- Validate payload semantics by fork version, matching execution-apis + execution-specs + EIP rules.
- Keep methods atomic and testable; one public API entry point per focused unit with matching tests.
