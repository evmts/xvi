# [pass 1/5] phase-6-jsonrpc (JSON-RPC Server) - Focused Context

## 1) Phase Goal and Deliverables
Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

Phase 6 goal is to implement the Ethereum JSON-RPC API with these planned modules:
- `client/rpc/server.zig` - HTTP/WebSocket entrypoint and request lifecycle
- `client/rpc/eth.zig` - `eth_*` methods
- `client/rpc/net.zig` - `net_*` methods
- `client/rpc/web3.zig` - `web3_*` methods

Primary architecture reference for module boundaries:
- `nethermind/src/Nethermind/Nethermind.JsonRpc/`

Primary method/schema reference:
- `execution-apis/src/eth/`

## 2) Specs to Read Before Implementation
Source map: `prd/ETHEREUM_SPECS_REFERENCE.md`

### JSON-RPC method and payload specs
- `execution-apis/src/eth/block.yaml`
- `execution-apis/src/eth/client.yaml`
- `execution-apis/src/eth/execute.yaml`
- `execution-apis/src/eth/fee_market.yaml`
- `execution-apis/src/eth/filter.yaml`
- `execution-apis/src/eth/sign.yaml`
- `execution-apis/src/eth/state.yaml`
- `execution-apis/src/eth/submit.yaml`
- `execution-apis/src/eth/transaction.yaml`

### Shared RPC schema types (canonical wire format constraints)
- `execution-apis/src/schemas/base-types.yaml`
- `execution-apis/src/schemas/block.yaml`
- `execution-apis/src/schemas/transaction.yaml`
- `execution-apis/src/schemas/receipt.yaml`
- `execution-apis/src/schemas/state.yaml`
- `execution-apis/src/schemas/filter.yaml`
- `execution-apis/src/schemas/execute.yaml`
- `execution-apis/src/schemas/client.yaml`

### EIPs relevant to RPC behavior
- `EIPs/EIPS/eip-1474.md`
  - JSON-RPC envelope, Ethereum RPC error codes, `Quantity` and `Data` encoding constraints.
- `EIPs/EIPS/eip-1898.md`
  - Block selector object (`blockHash`/`blockNumber` + `requireCanonical`) for state query methods.
- `EIPs/EIPS/eip-695.md`
  - `eth_chainId` semantics and output expectations.

### Execution-specs references for canonical block/tx/receipt structures
- `execution-specs/src/ethereum/forks/prague/blocks.py`
- `execution-specs/src/ethereum/forks/prague/fork.py`
- `execution-specs/src/ethereum/forks/osaka/blocks.py`

These files are useful when mapping chain data into RPC response objects (`eth_getBlock*`, `eth_getTransaction*`, `eth_getTransactionReceipt`, logs).

### devp2p references relevant to `net_version`
- `devp2p/caps/eth.md`
  - `Status` message includes `networkid`; spec explicitly notes Network ID may differ from EIP-155 Chain ID.

## 3) Nethermind Structural References

### 3.1 JSON-RPC module shape
Directory: `nethermind/src/Nethermind/Nethermind.JsonRpc/`

Key files/directories:
- `JsonRpcProcessor.cs`
- `JsonRpcRequest.cs`
- `JsonRpcResponse.cs`
- `JsonRpcService.cs`
- `JsonRpcConfig.cs`
- `Error.cs`
- `ErrorCodes.cs`
- `Modules/`
- `Converters/`
- `WebSockets/`

Use this as structural guidance only; implement idiomatically in Zig with comptime DI.

### 3.2 DB layer files requested for review
Directory: `nethermind/src/Nethermind/Nethermind.Db/`

Key files noted:
- Interfaces: `IDb.cs`, `IReadOnlyDb.cs`, `IColumnsDb.cs`, `IFullDb.cs`, `IDbProvider.cs`, `IDbFactory.cs`
- Providers/impl: `DbProvider.cs`, `DbProviderExtensions.cs`, `ReadOnlyDbProvider.cs`, `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `ReadOnlyColumnsDb.cs`
- Batching: `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`
- Configuration/utilities: `RocksDbSettings.cs`, `RocksDbMergeEnumerator.cs`, `DbNames.cs`, `DbExtensions.cs`
- Data columns/keys: `ReceiptsColumns.cs`, `BlobTxsColumns.cs`, `MetadataDbKeys.cs`
- Pruning: `IPruningConfig.cs`, `PruningConfig.cs`, `PruningMode.cs`, `FullPruning/`

## 4) Voltaire APIs to Reuse (No Custom RPC Types)
Base directory: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

### JSON-RPC module
- `jsonrpc/root.zig`
- `jsonrpc/JsonRpc.zig`
  - `JsonRpcMethod` union (`engine`, `eth`, `debug`) and `methodName()` dispatch helper.
- `jsonrpc/eth/methods.zig`
  - Typed `EthMethod` union with params/results for `eth_*` methods.
- `jsonrpc/engine/methods.zig`
- `jsonrpc/debug/methods.zig`

### Shared RPC types
- `jsonrpc/types.zig`
- `jsonrpc/types/Address.zig`
- `jsonrpc/types/Hash.zig`
- `jsonrpc/types/Quantity.zig`
- `jsonrpc/types/BlockTag.zig`
- `jsonrpc/types/BlockSpec.zig`

### Primitives commonly needed by RPC handlers/results
- `primitives/Address/address.zig`
- `primitives/Hash/Hash.zig`
- `primitives/Block/Block.zig`
- `primitives/BlockHeader/BlockHeader.zig`
- `primitives/BlockNumber/BlockNumber.zig`
- `primitives/Transaction/Transaction.zig`
- `primitives/TransactionHash/TransactionHash.zig`
- `primitives/Receipt/Receipt.zig`
- `primitives/Bytes/Bytes.zig`
- `primitives/Hex/Hex.zig`
- `primitives/AccessList/access_list.zig`
- `primitives/ChainId/ChainId.zig`
- `primitives/NetworkId/NetworkId.zig`
- `primitives/FilterId/filter_id.zig`
- `primitives/BlockFilter/block_filter.zig`
- `primitives/PendingTransactionFilter/pending_transaction_filter.zig`

### Other supporting Voltaire modules
- `blockchain/Blockchain.zig`
- `blockchain/BlockStore.zig`
- `state-manager/StateManager.zig`

## 5) Existing Zig Integration Surface
- `guillotine-mini/src/host.zig`

`HostInterface` currently exposes vtable-backed external state operations:
- `getBalance` / `setBalance`
- `getCode` / `setCode`
- `getStorage` / `setStorage`
- `getNonce` / `setNonce`

Important note from file comments:
- Nested calls are handled in EVM internals; host interface is for external state access.

## 6) Test Fixture Paths to Reuse

### ethereum-tests directories (requested listing)
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

### Concrete fixture file examples
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP3675/timestampPerBlock.json`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bc4895-withdrawals/accountInteractions.json`
- `ethereum-tests/TransactionTests/ttEIP1559/maxFeePerGasOverflow.json`
- `ethereum-tests/TransactionTests/ttAddress/AddressMoreThan20.json`
- `ethereum-tests/TrieTests/trietest.json`
- `ethereum-tests/ABITests/basic_abi_tests.json`

### Additional RPC-focused suites
- `execution-spec-tests/`
- `hive/`

## 7) Implementation Guardrails for Next Step
- Use Voltaire JSON-RPC and primitive types directly; do not define duplicate custom wire types.
- Keep EVM execution on existing guillotine-mini implementation; do not reimplement EVM behavior.
- Follow Nethermind module boundaries, but use Zig comptime DI patterns for handler wiring/dispatch.
- Enforce EIP-1474 error code behavior and hex encoding rules.
- Ensure block selector handling conforms to EIP-1898 object semantics.
