# [pass 1/5] phase-6-jsonrpc (JSON-RPC Server) - focused context

## Phase goals (from `prd/GUILLOTINE_CLIENT_PLAN.md`)
Phase 6 goal: implement Ethereum JSON-RPC surface.

Planned components:
- `client/rpc/server.zig` - HTTP/WebSocket server
- `client/rpc/eth.zig` - `eth_*` namespace
- `client/rpc/net.zig` - `net_*` namespace
- `client/rpc/web3.zig` - `web3_*` namespace

Primary structural references:
- `nethermind/src/Nethermind/Nethermind.JsonRpc/`
- `execution-apis/src/eth/`

## Specs index (from `prd/ETHEREUM_SPECS_REFERENCE.md`)
Phase 6 specs called out:
- `execution-apis/src/eth/` (OpenRPC)
- `EIPs/EIPS/eip-1474.md` (RPC wire rules)

Phase 6 test references called out:
- `hive/`
- `execution-spec-tests/`

## Spec files gathered

### OpenRPC method groups
- `execution-apis/src/eth/block.yaml` - block lookups, tx/uncle counts, receipts
- `execution-apis/src/eth/client.yaml` - chain id, syncing, coinbase, accounts, block number, network id
- `execution-apis/src/eth/execute.yaml` - call/estimate/simulate execution paths
- `execution-apis/src/eth/fee_market.yaml` - gas price, blob base fee, fee history, priority fee
- `execution-apis/src/eth/filter.yaml` - filter install/query/uninstall
- `execution-apis/src/eth/sign.yaml` - sign/signTransaction
- `execution-apis/src/eth/state.yaml` - balance/storage/nonce/code/proof reads
- `execution-apis/src/eth/submit.yaml` - submit tx and raw tx
- `execution-apis/src/eth/transaction.yaml` - tx and receipt lookup APIs

### EIP constraints for server behavior
- `EIPs/EIPS/eip-1474.md`
  - JSON-RPC error code set
  - strict `Quantity` and `Data` encoding requirements
  - block identifier semantics and error behavior expectations

## Nethermind context

### Requested DB inventory (`nethermind/src/Nethermind/Nethermind.Db/`)
Key files noted:
- `DbProvider.cs`, `IDbProvider.cs`, `IReadOnlyDbProvider.cs`, `ReadOnlyDbProvider.cs`
- `IDb.cs`, `IReadOnlyDb.cs`, `IColumnsDb.cs`, `IFullDb.cs`, `IDbFactory.cs`
- `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `ReadOnlyColumnsDb.cs`
- `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`
- `ReceiptsColumns.cs`, `BlobTxsColumns.cs`, `MetadataDbKeys.cs`
- `RocksDbSettings.cs`, `RocksDbMergeEnumerator.cs`, `CompressingDb.cs`
- `IPruningConfig.cs`, `PruningConfig.cs`, `PruningMode.cs`, `FullPruning/*`

### JSON-RPC architecture reference (`nethermind/src/Nethermind/Nethermind.JsonRpc/`)
Key shape to mirror idiomatically in Zig:
- request/response pipeline (`JsonRpcRequest.cs`, `JsonRpcResponse.cs`, `JsonRpcProcessor.cs`, `JsonRpcService.cs`)
- error model (`ErrorCodes.cs`, `Error.cs`)
- module dispatch and filtering (`Modules/*`)

## Voltaire APIs to use (no custom duplicate types)
Base: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

JSON-RPC entry points:
- `jsonrpc/root.zig`
- `jsonrpc/JsonRpc.zig`
- `jsonrpc/eth/methods.zig`
- `jsonrpc/engine/methods.zig`
- `jsonrpc/types.zig`

Shared RPC primitives:
- `jsonrpc/types/Address.zig`
- `jsonrpc/types/Hash.zig`
- `jsonrpc/types/Quantity.zig`
- `jsonrpc/types/BlockTag.zig`
- `jsonrpc/types/BlockSpec.zig`

Notable behaviors observed in Voltaire:
- union-based method dispatch via `methodName()` and `fromMethodName()`
- generated method wrappers expose `Params`/`Result` with JSON parse/stringify hooks

## Existing Zig host interface
Requested path `src/host.zig` is not present at repository root.
Equivalent file in this workspace:
- `guillotine-mini/src/host.zig`

`HostInterface` summary:
- pointer + vtable interface
- methods: `getBalance`, `setBalance`, `getCode`, `setCode`, `getStorage`, `setStorage`, `getNonce`, `setNonce`
- comments indicate nested EVM calls are handled internally, not through this host vtable

## Test fixture paths

### Ethereum tests directories
- `ethereum-tests/ABITests/`
- `ethereum-tests/BasicTests/`
- `ethereum-tests/BlockchainTests/`
- `ethereum-tests/DifficultyTests/`
- `ethereum-tests/EOFTests/`
- `ethereum-tests/GenesisTests/`
- `ethereum-tests/KeyStoreTests/`
- `ethereum-tests/LegacyTests/`
- `ethereum-tests/PoWTests/`
- `ethereum-tests/RLPTests/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/JSONSchema/`

Useful fixture subpaths for RPC-related integration:
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/TransactionTests/ttEIP1559/`
- `ethereum-tests/TransactionTests/ttEIP2930/`
- `ethereum-tests/TransactionTests/ttGasPrice/`
- `ethereum-tests/TransactionTests/ttWrongRLP/`

Related harness paths:
- `execution-spec-tests/fixtures/blockchain_tests` (symlink to `ethereum-tests/BlockchainTests`)
- `hive/simulators/` (RPC compatibility simulators)

## Implementation direction for phase 6
- Keep transport and dispatch separated: server transport -> method decode -> backend call -> spec-conformant response.
- Reuse Voltaire JSON-RPC method/types as canonical wire contracts.
- Follow Nethermind-style processor/service/module boundaries, but implement with Zig comptime DI and small testable units.
- Preserve existing guillotine-mini EVM boundaries; do not reimplement execution logic in RPC handlers.
- Enforce EIP-1474 encoding and error semantics in request validation and response generation.
