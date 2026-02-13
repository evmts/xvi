# [pass 2/5] phase-6-jsonrpc (JSON-RPC Server) — Context

## 1) Phase goal (PRD)

Source: `prd/GUILLOTINE_CLIENT_PLAN.md` (Phase 6 section)

- Goal: implement Ethereum JSON-RPC API.
- Planned components:
  - `client/rpc/server.zig`
  - `client/rpc/eth.zig`
  - `client/rpc/net.zig`
  - `client/rpc/web3.zig`
- Primary references:
  - `nethermind/src/Nethermind/Nethermind.JsonRpc/`
  - `execution-apis/src/eth/`

Source: `prd/ETHEREUM_SPECS_REFERENCE.md` (Phase 6 section)

- Specs called out:
  - `execution-apis/src/eth/`
  - `EIPs/EIPS/eip-1474.md`
- Tests called out:
  - `hive/` (RPC suites)
  - `execution-spec-tests/` (RPC fixtures)

## 2) Spec files to read before implementation

### Core JSON-RPC API specs

- `execution-apis/src/eth/client.yaml`
  - Client/network methods: `eth_chainId`, `eth_syncing`, `eth_coinbase`, `eth_accounts`, `eth_blockNumber`, `net_version`.
- `execution-apis/src/eth/state.yaml`
  - State-query methods: `eth_getBalance`, `eth_getStorageAt`, `eth_getTransactionCount`, `eth_getCode`, `eth_getProof`.
- `execution-apis/src/eth/block.yaml`
  - Block/uncle retrieval and block transaction counts.
- `execution-apis/src/eth/transaction.yaml`
  - Transaction and receipt retrieval methods.
- `execution-apis/src/eth/fee_market.yaml`
  - Fee market methods (`eth_gasPrice`, `eth_feeHistory`, etc.).
- `execution-apis/src/eth/filter.yaml`
  - Filter and logs API (`eth_newFilter`, `eth_getLogs`, etc.).
- `execution-apis/src/eth/execute.yaml`
  - Execution simulation methods (`eth_call`, `eth_estimateGas`).
- `execution-apis/src/eth/sign.yaml`
  - Signing methods.
- `execution-apis/src/eth/submit.yaml`
  - Transaction submission methods.

### EIP JSON-RPC semantics

- `EIPs/EIPS/eip-1474.md`
  - Defines JSON-RPC envelope expectations, canonical error codes/messages, and Quantity/Data encoding rules.
- `EIPs/EIPS/eip-1898.md`
  - Block identifier object semantics for state-query methods (used by methods referenced from EIP-1474).

## 3) Nethermind architecture references

### JSON-RPC module (primary)

Directory: `nethermind/src/Nethermind/Nethermind.JsonRpc/`

Key server/pipeline files:
- `nethermind/src/Nethermind/Nethermind.JsonRpc/JsonRpcProcessor.cs`
- `nethermind/src/Nethermind/Nethermind.JsonRpc/JsonRpcService.cs`
- `nethermind/src/Nethermind/Nethermind.JsonRpc/JsonRpcRequest.cs`
- `nethermind/src/Nethermind/Nethermind.JsonRpc/JsonRpcResponse.cs`
- `nethermind/src/Nethermind/Nethermind.JsonRpc/ErrorCodes.cs`

Key module structure:
- `nethermind/src/Nethermind/Nethermind.JsonRpc/Modules/Eth/EthRpcModule.cs`
- `nethermind/src/Nethermind/Nethermind.JsonRpc/Modules/Net/NetRpcModule.cs`
- `nethermind/src/Nethermind/Nethermind.JsonRpc/Modules/Web3/Web3RpcModule.cs`
- `nethermind/src/Nethermind/Nethermind.JsonRpc/Modules/Subscribe/SubscribeRpcModule.cs`

### Db layer (requested inventory)

Directory listed: `nethermind/src/Nethermind/Nethermind.Db/`

Key files to keep in mind for RPC-backed read paths:
- `nethermind/src/Nethermind/Nethermind.Db/DbProvider.cs`
- `nethermind/src/Nethermind/Nethermind.Db/IDbProvider.cs`
- `nethermind/src/Nethermind/Nethermind.Db/IDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/IReadOnlyDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/IColumnsDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/RocksDbSettings.cs`
- `nethermind/src/Nethermind/Nethermind.Db/ReadOnlyDbProvider.cs`
- `nethermind/src/Nethermind/Nethermind.Db/ReceiptsColumns.cs`
- `nethermind/src/Nethermind/Nethermind.Db/BlobTxsColumns.cs`

## 4) Voltaire APIs to use (no custom duplicate types)

Base directory listed: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

### JSON-RPC primitives and method unions

- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/root.zig`
  - Exposes `JsonRpc`, `eth`, `debug`, `engine`, shared `types`.
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/JsonRpc.zig`
  - Root `JsonRpcMethod` union with namespace dispatch.
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig`
  - `EthMethod` union + `fromMethodName`/`methodName`.
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types.zig`
  - Shared JSON-RPC types module.
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Quantity.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockSpec.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/BlockTag.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Address.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Hash.zig`

### Domain primitives and chain data

- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/root.zig`
  - Canonical Ethereum types: `Address`, `Hash`, `Block`, `Transaction`, `Receipt`, `Nonce`, `ChainId`, etc.
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/root.zig`
  - `BlockStore`, `ForkBlockCache`, `Blockchain`.

## 5) Existing Zig code in this repo (current RPC baseline)

### RPC module

Directory: `client/rpc/`

- `client/rpc/root.zig`
  - RPC public exports.
- `client/rpc/server.zig`
  - Config defaults, JSON-RPC version validation, top-level request kind parsing (single vs batch), batch-size limit checks.
- `client/rpc/dispatch.zig`
  - Method namespace resolution using Voltaire method unions.
- `client/rpc/scan.zig`
  - Allocation-free top-level JSON scanner (request field scan + validation).
- `client/rpc/envelope.zig`
  - Zero-copy request `id` extraction.
- `client/rpc/response.zig`
  - Allocation-free JSON-RPC success/error serializers, Quantity encoding helper.
- `client/rpc/error.zig`
  - EIP-1474 codes + Nethermind extension codes.
- `client/rpc/eth.zig`
  - Current `eth_chainId` handler via comptime DI (`EthApi(Provider)`).

### EVM host interface (requested read)

- Requested path `src/host.zig` is not present at repo root.
- Corresponding file in guillotine-mini: `guillotine-mini/src/host.zig`.
  - Defines `HostInterface` with vtable callbacks:
    - `getBalance` / `setBalance`
    - `getCode` / `setCode`
    - `getStorage` / `setStorage`
    - `getNonce` / `setNonce`
  - Note in file: nested calls are handled by EVM internals, not through this host interface.

## 6) Test fixtures and directories to target

### ethereum-tests (requested directory listing highlights)

- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/RLPTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/EOFTests/`

RPC-adjacent coverage signals from available dirs:
- `ethereum-tests/TransactionTests/ttEIP1559/`
- `ethereum-tests/TransactionTests/ttEIP2930/`
- `ethereum-tests/TransactionTests/ttWrongRLP/`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP1559/`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP4844-blobtransactions/`

### Additional phase-6 suites from PRD mapping

- `hive/` (RPC and integration behavior)
- `execution-spec-tests/src/ethereum_test_rpc/`
- `execution-spec-tests/src/pytest_plugins/execute/rpc/`

## 7) Immediate implementation implications for phase-6

- Keep method schema/typing anchored to Voltaire JSON-RPC unions and shared types; avoid local duplicate RPC value types.
- Follow Nethermind split: request pipeline/processor + namespace modules (`eth`, `net`, `web3`), but implement with Zig comptime DI.
- Reuse existing allocation-free scanner/envelope/response path in `client/rpc/` as the base dispatch pipeline.
- Add `net_*` and `web3_*` handling next to existing `eth_*` flow, with explicit EIP-1474 error mapping.
