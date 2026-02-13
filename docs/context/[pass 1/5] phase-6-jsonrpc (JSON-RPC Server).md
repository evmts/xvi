# [pass 1/5] phase-6-jsonrpc (JSON-RPC Server) - focused context

## Phase goal (`prd/GUILLOTINE_CLIENT_PLAN.md`)
Phase 6 goal is to implement the Ethereum JSON-RPC server layer:
- `client/rpc/server.zig` (HTTP/WebSocket server pipeline)
- `client/rpc/eth.zig` (`eth_*` methods)
- `client/rpc/net.zig` (`net_*` methods)
- `client/rpc/web3.zig` (`web3_*` methods)

Reference boundaries:
- Architecture shape: `nethermind/src/Nethermind/Nethermind.JsonRpc/`
- Method/spec source: `execution-apis/src/eth/`

## Specs and references read

### Product/spec index
- `prd/ETHEREUM_SPECS_REFERENCE.md`
  - Phase 6 mapping confirms: `execution-apis/src/eth/` + `EIPs/EIPS/eip-1474.md`
  - Notes RPC test surfaces: `hive/` and `execution-spec-tests/`

### OpenRPC method specs (`execution-apis/src/eth/`)
- `execution-apis/src/eth/block.yaml`
  - Block retrieval/count methods: `eth_getBlockByHash`, `eth_getBlockByNumber`, tx/uncle counts, `eth_getBlockReceipts`
- `execution-apis/src/eth/client.yaml`
  - Client/network methods: `eth_chainId`, `eth_syncing`, `eth_coinbase`, `eth_accounts`, `eth_blockNumber`, `net_version`
- `execution-apis/src/eth/execute.yaml`
  - Execution methods: `eth_call`, `eth_estimateGas`, `eth_createAccessList`, `eth_simulateV1`
- `execution-apis/src/eth/fee_market.yaml`
  - Fee methods: `eth_gasPrice`, `eth_blobBaseFee`, `eth_maxPriorityFeePerGas`, `eth_feeHistory`
- `execution-apis/src/eth/filter.yaml`
  - Filter lifecycle: create/listen/uninstall/get changes/logs
- `execution-apis/src/eth/sign.yaml`
  - Signing methods: `eth_sign`, `eth_signTransaction`
- `execution-apis/src/eth/state.yaml`
  - State queries: `eth_getBalance`, `eth_getStorageAt`, `eth_getTransactionCount`, `eth_getCode`, `eth_getProof`
- `execution-apis/src/eth/submit.yaml`
  - Submission methods: `eth_sendTransaction`, `eth_sendRawTransaction`
- `execution-apis/src/eth/transaction.yaml`
  - Transaction and receipt queries by hash/block/index

### Shared wire schemas (`execution-apis/src/schemas/`)
- `execution-apis/src/schemas/base-types.yaml`
  - Canonical JSON-RPC wire constraints for `uint`, `hash32`, `address`, `bytes*`
- `execution-apis/src/schemas/block.yaml`
  - `BlockTag`, `BlockNumberOrTag`, `BlockNumberOrTagOrHash` (critical for default block params)
- `execution-apis/src/schemas/state.yaml`
  - Account proof and storage proof schema shapes

### EIP-level RPC requirements
- `EIPs/EIPS/eip-1474.md`
  - JSON-RPC envelope and Ethereum RPC error code table
  - Strict `Quantity` vs `Data` encoding rules
  - Block identifier semantics and error precedence guidance
- `EIPs/EIPS/eip-1898.md`
  - Extended block parameter object (`blockNumber` or `blockHash`, `requireCanonical`)
  - Required precedence: block-not-found before canonicality failure

### Execution semantics backing RPC responses
- `execution-specs/src/ethereum/forks/prague/fork.py`
  - Block/state transition entry points (`state_transition`, header validation flow)
- `execution-specs/src/ethereum/forks/prague/state.py`
  - State model, snapshot/commit/rollback, account/storage access primitives
- `execution-specs/src/ethereum/forks/prague/vm/__init__.py`
  - EVM environment/message structures used by call execution semantics

### Network context for `net_*`
- `devp2p/caps/eth.md`
  - Current ETH wire protocol session behavior and chain/network context relevant to `net_version`/peer count surfaces

## Nethermind reference inventory

### Requested DB directory inventory (`nethermind/src/Nethermind/Nethermind.Db/`)
Key files to mirror as architectural concepts (not C# implementation):
- Provider and interfaces:
  - `DbProvider.cs`, `IDbProvider.cs`, `IReadOnlyDbProvider.cs`, `ReadOnlyDbProvider.cs`
  - `IDb.cs`, `IReadOnlyDb.cs`, `IColumnsDb.cs`, `IFullDb.cs`, `IDbFactory.cs`
- In-memory and wrappers:
  - `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `ReadOnlyColumnsDb.cs`
  - `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`
- Columns/keys/settings/pruning:
  - `ReceiptsColumns.cs`, `BlobTxsColumns.cs`, `MetadataDbKeys.cs`
  - `RocksDbSettings.cs`, `RocksDbMergeEnumerator.cs`, `CompressingDb.cs`
  - `IPruningConfig.cs`, `PruningConfig.cs`, `PruningMode.cs`, `FullPruning/*`

### JSON-RPC architecture shape (`nethermind/src/Nethermind/Nethermind.JsonRpc/`)
- Request/response lifecycle:
  - `JsonRpcProcessor.cs`, `JsonRpcService.cs`, `JsonRpcRequest.cs`, `JsonRpcResponse.cs`, `JsonRpcResult.cs`
- Error model:
  - `ErrorCodes.cs`, `Error.cs`
- Module and dispatch structure:
  - `Modules/*` (module provider/pool/factory/method filtering pattern)

## Voltaire primitives/APIs to use (no custom duplicates)
Base path:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

Primary JSON-RPC type system:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig`

Critical shared RPC types:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Hash.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockTag.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockSpec.zig`

Supporting runtime domains:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/root.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/root.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/root.zig`

## Existing EVM host interface
Requested path `src/host.zig` resolves in this repository as:
- `guillotine-mini/src/host.zig`

Observed host pattern:
- `HostInterface` is pointer + vtable indirection
- Methods exposed: `getBalance`, `setBalance`, `getCode`, `setCode`, `getStorage`, `setStorage`, `getNonce`, `setNonce`
- Existing EVM comments indicate nested calls are handled in EVM internals; host interface covers external state access

## Test fixture paths

### Ethereum tests directory inventory (`ethereum-tests/`)
- `ethereum-tests/BlockchainTests/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/EOFTests/`
- `ethereum-tests/RLPTests/`
- `ethereum-tests/BasicTests/`
- `ethereum-tests/DifficultyTests/`
- `ethereum-tests/GenesisTests/`
- `ethereum-tests/LegacyTests/`
- `ethereum-tests/PoWTests/`
- `ethereum-tests/JSONSchema/`

### Useful JSON fixture subpaths for phase 6 coverage
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/TransactionTests/ttEIP1559/`
- `ethereum-tests/TransactionTests/ttEIP2930/`
- `ethereum-tests/TransactionTests/ttGasPrice/`
- `ethereum-tests/TransactionTests/ttWrongRLP/`
- `ethereum-tests/TrieTests/`

### Additional RPC-focused suites
- `execution-spec-tests/src/ethereum_test_rpc/`
- `hive/simulators/ethereum/rpc-compat/`

## Implementation guardrails for phase 6
- Use Voltaire JSON-RPC and primitive types directly; do not create duplicate wire/domain types.
- Reuse existing guillotine-mini EVM and host integration points; do not reimplement EVM behavior.
- Follow Nethermind module boundaries conceptually (processor/service/modules), but implement idiomatically in Zig.
- Use comptime DI patterns for method routing and backend dependency injection.
- Enforce EIP-1474 encoding/error semantics and EIP-1898 block selector behavior exactly.
