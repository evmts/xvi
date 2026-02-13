# [pass 1/5] phase-6-jsonrpc (JSON-RPC Server) - focused context

## Phase goal (from `prd/GUILLOTINE_CLIENT_PLAN.md`)
Phase 6 goal is to implement the Ethereum JSON-RPC server layer with:
- `client/rpc/server.zig` (HTTP/WebSocket request pipeline)
- `client/rpc/eth.zig` (`eth_*` methods)
- `client/rpc/net.zig` (`net_*` methods)
- `client/rpc/web3.zig` (`web3_*` methods)

Primary structural reference:
- `nethermind/src/Nethermind/Nethermind.JsonRpc/`

Primary method spec source:
- `execution-apis/src/eth/`

## Relevant specs read (from `prd/ETHEREUM_SPECS_REFERENCE.md`)
### JSON-RPC method definitions
- `execution-apis/src/eth/block.yaml`
- `execution-apis/src/eth/client.yaml`
- `execution-apis/src/eth/execute.yaml`
- `execution-apis/src/eth/fee_market.yaml`
- `execution-apis/src/eth/filter.yaml`
- `execution-apis/src/eth/sign.yaml`
- `execution-apis/src/eth/state.yaml`
- `execution-apis/src/eth/submit.yaml`
- `execution-apis/src/eth/transaction.yaml`

### Shared schema types for wire encoding
- `execution-apis/src/schemas/base-types.yaml`
- `execution-apis/src/schemas/block.yaml`
- `execution-apis/src/schemas/client.yaml`
- `execution-apis/src/schemas/execute.yaml`
- `execution-apis/src/schemas/filter.yaml`
- `execution-apis/src/schemas/receipt.yaml`
- `execution-apis/src/schemas/state.yaml`
- `execution-apis/src/schemas/transaction.yaml`

### EIP requirements directly affecting RPC behavior
- `EIPs/EIPS/eip-1474.md`
  - JSON-RPC 2.0 envelope requirements
  - Ethereum RPC error codes (`-32700`..`-32006`)
  - strict `Quantity` and `Data` hex encoding rules
- `EIPs/EIPS/eip-1898.md`
  - block selector object semantics (`blockNumber` or `blockHash`, optional `requireCanonical`)
  - precedence: block-not-found before canonicality failure
- `EIPs/EIPS/eip-695.md`
  - `eth_chainId` behavior

### execution-specs and devp2p notes
- `execution-specs/README.md` explicitly points JSON-RPC spec to `execution-apis`.
- `devp2p/caps/eth.md` provides `networkid` context used by `net_version` semantics.

## Nethermind reference inventory
### JSON-RPC architecture (`nethermind/src/Nethermind/Nethermind.JsonRpc/`)
Core request lifecycle files:
- `JsonRpcProcessor.cs` (parse/stream/process request objects)
- `JsonRpcService.cs` (method resolution, parameter binding, module rental)
- `JsonRpcRequest.cs`, `JsonRpcResponse.cs`, `JsonRpcResult.cs`
- `ErrorCodes.cs`, `Error.cs`

Module organization (shape to mirror in Zig, not code to port):
- `Modules/Eth/EthRpcModule.cs`
- `Modules/Net/NetRpcModule.cs`
- `Modules/Web3/Web3RpcModule.cs`
- `Modules/Module/RpcRpcModule.cs`
- `Modules/Subscribe/SubscribeRpcModule.cs`
- plus module provider/pool files under `Modules/`

### DB key files requested (`nethermind/src/Nethermind/Nethermind.Db/`)
Interfaces and providers:
- `IDb.cs`, `IReadOnlyDb.cs`, `IColumnsDb.cs`, `IFullDb.cs`
- `IDbFactory.cs`, `IDbProvider.cs`, `IReadOnlyDbProvider.cs`
- `DbProvider.cs`, `ReadOnlyDbProvider.cs`, `DbProviderExtensions.cs`

Implementations and write batching:
- `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `ReadOnlyColumnsDb.cs`
- `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`

Columns/config/pruning:
- `ReceiptsColumns.cs`, `BlobTxsColumns.cs`, `MetadataDbKeys.cs`
- `RocksDbSettings.cs`, `RocksDbMergeEnumerator.cs`, `CompressingDb.cs`
- `IPruningConfig.cs`, `PruningConfig.cs`, `PruningMode.cs`, `FullPruning/`

## Voltaire APIs to use (never custom duplicates)
Base path:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

JSON-RPC typed primitives:
- `jsonrpc/root.zig`
- `jsonrpc/JsonRpc.zig` (`JsonRpcMethod` union)
- `jsonrpc/eth/methods.zig` (`EthMethod` union and typed params/results)
- `jsonrpc/types.zig`
- `jsonrpc/types/Address.zig`
- `jsonrpc/types/Hash.zig`
- `jsonrpc/types/Quantity.zig`
- `jsonrpc/types/BlockTag.zig`
- `jsonrpc/types/BlockSpec.zig`

Voltaire primitive/state APIs commonly required by method handlers:
- `primitives/Address/address.zig`
- `primitives/Block/Block.zig`
- `primitives/BlockHeader/BlockHeader.zig`
- `primitives/BlockNumber/BlockNumber.zig`
- `primitives/Hash/Hash.zig`
- `primitives/Transaction/Transaction.zig`
- `primitives/TransactionHash/TransactionHash.zig`
- `primitives/Receipt/Receipt.zig`
- `primitives/Gas/Gas.zig`
- `primitives/ChainId/ChainId.zig`
- `primitives/NetworkId/NetworkId.zig`
- `primitives/Nonce/Nonce.zig`
- `primitives/SyncStatus/SyncStatus.zig`
- `state-manager/StateManager.zig`
- `blockchain/Blockchain.zig`

## Existing Zig host interface
Requested path was `src/host.zig`; in this repo the file is:
- `guillotine-mini/src/host.zig`

Key interface summary:
- `HostInterface` is pointer + vtable based DI surface
- exposes `get/setBalance`, `get/setCode`, `get/setStorage`, `get/setNonce`
- comments state nested calls are handled by EVM internals, not via host indirection

## Ethereum test fixture paths (directory inventory)
Primary directories in `ethereum-tests/`:
- `ethereum-tests/BlockchainTests/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/BasicTests/`
- `ethereum-tests/EOFTests/`
- `ethereum-tests/RLPTests/`
- `ethereum-tests/DifficultyTests/`
- `ethereum-tests/GenesisTests/`
- `ethereum-tests/LegacyTests/`
- `ethereum-tests/PoWTests/`
- `ethereum-tests/JSONSchema/`

Useful subpaths for tx/block coverage:
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/TransactionTests/ttEIP1559/`
- `ethereum-tests/TransactionTests/ttEIP2930/`
- `ethereum-tests/TransactionTests/ttGasPrice/`
- `ethereum-tests/TransactionTests/ttWrongRLP/`

Additional RPC validation suites:
- `execution-apis/tests/`
- `execution-spec-tests/`
- `hive/`

## Implementation guardrails for phase 6
- Use only Voltaire JSON-RPC/primitives/state types; do not define duplicate RPC wire types.
- Keep EVM behavior delegated to existing guillotine-mini EVM.
- Mirror Nethermind boundaries at high level (processor/service/modules) but implement with Zig comptime DI.
- Enforce EIP-1474 error/encoding requirements and EIP-1898 block selector behavior.
