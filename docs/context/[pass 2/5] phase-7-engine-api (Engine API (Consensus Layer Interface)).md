# [pass 2/5] phase-7-engine-api (Engine API (Consensus Layer Interface))

## Phase Goal (from PRD)

Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

- Goal: implement the Engine API for consensus-layer communication.
- Planned components:
  - `client/engine/api.zig` (Engine API surface)
  - `client/engine/payload.zig` (payload build/validation)
- Architectural reference target:
  - `nethermind/src/Nethermind/Nethermind.Merge.Plugin/`

## Relevant Specs (from spec reference + direct files)

Source map: `prd/ETHEREUM_SPECS_REFERENCE.md`

### Engine API canonical specs

Primary directory: `execution-apis/src/engine/`

Core files read:
- `execution-apis/src/engine/README.md`
- `execution-apis/src/engine/common.md`
- `execution-apis/src/engine/authentication.md`
- `execution-apis/src/engine/identification.md`
- `execution-apis/src/engine/paris.md`
- `execution-apis/src/engine/shanghai.md`
- `execution-apis/src/engine/cancun.md`
- `execution-apis/src/engine/prague.md`
- `execution-apis/src/engine/osaka.md`
- `execution-apis/src/engine/amsterdam.md`
- `execution-apis/src/engine/openrpc/methods/*.yaml`
- `execution-apis/src/engine/openrpc/schemas/*.yaml`

Implementation-relevant points:
- Engine namespace default authenticated port is `8551`.
- JWT auth requires HS256 support (`authentication.md`).
- Ordering constraint: `engine_forkchoiceUpdated` calls must be processed in order (`common.md`).
- Error codes to preserve: `-38002` (invalid forkchoice), `-38003` (invalid payload attrs), plus JSON-RPC standard errors.
- `engine_exchangeCapabilities` is required on EL side and must not include itself in response.
- Fork versioning progression:
  - Paris: V1 payload/forkchoice/getPayload/transition config
  - Shanghai: V2 adds withdrawals + payload bodies methods
  - Cancun: V3 adds blob gas fields + `engine_getBlobsV1`
  - Prague/Osaka/Amsterdam extend methods and payload fields further

### EIPs tied to Engine API behavior

- `EIPs/EIPS/eip-3675.md` (Merge transition, terminal total difficulty, PoS header constraints)
- `EIPs/EIPS/eip-4399.md` (PREVRANDAO: `DIFFICULTY(0x44)` semantic shift to `mixHash/prevRandao`)
- `EIPs/EIPS/eip-4895.md` (withdrawals, Shanghai payload implications)
- `EIPs/EIPS/eip-4844.md` (blob transactions, Cancun payload implications)
- `EIPs/EIPS/eip-4788.md` (beacon root exposure; relevant for post-Merge header fields)

### execution-specs fixture model references

- `execution-specs/src/ethereum_spec_tests/ethereum_test_fixtures/blockchain.py`

Notable fixture structures for engine-facing tests:
- `FixtureExecutionPayload`
- `FixtureEngineNewPayload`
- Engine new payload parameter forms (V1/V3/V4 style tuples)
- Fork-conditional header/payload fields (withdrawals, blob gas, parent beacon root, requests)

## Nethermind Structural References

### Required architecture reference (phase target)

Directory: `nethermind/src/Nethermind/Nethermind.Merge.Plugin/`

High-value files and groups:
- RPC module split by fork:
  - `EngineRpcModule.cs`
  - `EngineRpcModule.Paris.cs`
  - `EngineRpcModule.Shanghai.cs`
  - `EngineRpcModule.Cancun.cs`
  - `EngineRpcModule.Prague.cs`
  - `EngineRpcModule.Osaka.cs`
- Handler layer:
  - `Handlers/NewPayloadHandler.cs`
  - `Handlers/ForkchoiceUpdatedHandler.cs`
  - `Handlers/GetPayloadV1Handler.cs`
  - `Handlers/GetPayloadV2Handler.cs`
  - `Handlers/GetPayloadV3Handler.cs`
  - `Handlers/GetPayloadV4Handler.cs`
  - `Handlers/GetPayloadV5Handler.cs`
  - `Handlers/GetPayloadBodiesByHashV1Handler.cs`
  - `Handlers/GetPayloadBodiesByRangeV1Handler.cs`
  - `Handlers/ExchangeCapabilitiesHandler.cs`
  - `Handlers/ExchangeTransitionConfigurationV1Handler.cs`
  - `Handlers/GetBlobsHandler.cs`
  - `Handlers/GetBlobsHandlerV2.cs`
- Data contracts:
  - `Data/ExecutionPayload.cs`
  - `Data/ExecutionPayloadV3.cs`
  - `Data/ForkchoiceStateV1.cs`
  - `Data/PayloadStatusV1.cs`
  - `Data/ForkchoiceUpdatedV1Result.cs`
  - `Data/TransitionConfigurationV1.cs`
  - `Data/ClientVersionV1.cs`

### Requested DB inventory (explicit task step)

Directory listed: `nethermind/src/Nethermind/Nethermind.Db/`

Key files noted:
- Interfaces: `IDb.cs`, `IReadOnlyDb.cs`, `IDbFactory.cs`, `IDbProvider.cs`, `IColumnsDb.cs`
- Providers/adapters: `DbProvider.cs`, `DbProviderExtensions.cs`, `DbExtensions.cs`, `ReadOnlyDbProvider.cs`
- Implementations: `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `NullDb.cs`
- Columns/metadata: `DbNames.cs`, `MetadataDbKeys.cs`, `ReceiptsColumns.cs`, `BlobTxsColumns.cs`
- Pruning/config: `PruningConfig.cs`, `PruningMode.cs`, `IPruningConfig.cs`, `FullPruning/`
- Support: `InMemoryWriteBatch.cs`, `RocksDbSettings.cs`, `Metrics.cs`

## Voltaire APIs (must be used, no custom duplicate types)

Base directory listed: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

Top-level modules relevant to phase-7:
- `jsonrpc/` (includes engine method models)
- `primitives/` (canonical Ethereum data types)
- `blockchain/`
- `state-manager/`
- `evm/` (already-existing EVM; do not reimplement)

Engine method registry and method modules:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/engine/methods.zig`
- Method folders present for:
  - `exchangeCapabilities`
  - `exchangeTransitionConfigurationV1`
  - `forkchoiceUpdatedV1/V2/V3`
  - `newPayloadV1..V5`
  - `getPayloadV1..V6`
  - `getPayloadBodiesByHashV1`
  - `getPayloadBodiesByRangeV1`
  - `getBlobsV1/V2`

Relevant primitive modules to reuse directly:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Block/Block.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockHeader/BlockHeader.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockHash/BlockHash.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Transaction/Transaction.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Withdrawal/Withdrawal.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BeaconBlockRoot/BeaconBlockRoot.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Hash/Hash.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Bytes32/Bytes32.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Rlp/Rlp.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Uint/Uint.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Address/address.zig`

## Existing Zig Host Interface

Requested file `src/host.zig` does not exist in this repo root.
Resolved host interface file:
- `guillotine-mini/src/host.zig`

Summary:
- Defines `HostInterface` with a vtable over state access primitives:
  - `getBalance` / `setBalance`
  - `getCode` / `setCode`
  - `getStorage` / `setStorage`
  - `getNonce` / `setNonce`
- Module comment notes nested call execution is handled inside EVM internals, not via this host interface.
- This is the existing comptime-injection style reference for host/state coupling.

## Ethereum Test Fixture Paths (task-required directory listing)

From `ethereum-tests/` (top-level dirs present):
- `ethereum-tests/BlockchainTests/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/DifficultyTests/`
- `ethereum-tests/GenesisTests/`
- `ethereum-tests/RLPTests/`
- `ethereum-tests/EOFTests/`
- `ethereum-tests/ABITests/`
- `ethereum-tests/BasicTests/`
- `ethereum-tests/LegacyTests/`
- `ethereum-tests/PoWTests/`

Additional Engine-focused suites available in submodules:
- `execution-spec-tests/fixtures/blockchain_tests/` (symlinked to blockchain tests in this workspace)
- `hive/simulators/ethereum/engine/`
- `hive/simulators/eth2/engine/`

## Implementation Guidance Extracted for Phase 7

- Keep engine surface fork-versioned and timestamp/fork-rule aware.
- Implement strict param-shape validation and exact error code semantics.
- Reuse Voltaire jsonrpc/primitives types; avoid local duplicate payload or hash/address types.
- Mirror Nethermind separation of concerns (rpc facade -> handlers -> payload/forkchoice services), but write idiomatic Zig with small testable units and comptime DI.
