# [pass 1/5] phase-5-txpool (Transaction Pool) — Context

## Phase Goal (from `prd/GUILLOTINE_CLIENT_PLAN.md`)
- Implement the transaction pool for pending transactions.
- Planned units:
  - `client/txpool/pool.zig` (pool admission/storage lifecycle)
  - `client/txpool/sorter.zig` (priority ordering by effective tip / fee)
- Structural reference: `nethermind/src/Nethermind/Nethermind.TxPool/`.

## Spec Priority and Required Reads
Source priority from `prd/ETHEREUM_SPECS_REFERENCE.md`: `execution-specs/` -> `EIPs/` -> tests -> `devp2p/`.

### Normative EIPs for TxPool admission/sorting
- `EIPs/EIPS/eip-2718.md`
  - Typed envelope (`tx_type || payload`), transaction type byte range, typed/legacy differentiation.
- `EIPs/EIPS/eip-2930.md`
  - Type-1 tx encoding and access-list format/gas charges.
- `EIPs/EIPS/eip-1559.md`
  - Type-2 fee market semantics (`max_fee_per_gas`, `max_priority_fee_per_gas`, basefee constraints).
- `EIPs/EIPS/eip-4844.md`
  - Type-3 blob tx constraints (`max_fee_per_blob_gas`, blob hash version checks, gossip-side wrapped payload rules).
- `EIPs/EIPS/eip-7702.md`
  - Future txpool compatibility target for type-4 authorization txs (Prague/Osaka evolution).

### Execution-specs files to mirror for validation behavior
- `execution-specs/src/ethereum/forks/cancun/transactions.py`
  - Canonical tx type models (legacy/2930/1559/4844), encode/decode rules, intrinsic gas, sender recovery, signing hashes.
- `execution-specs/src/ethereum/forks/cancun/fork.py`
  - Inclusion-time checks affecting pool pre-validation (blob gas availability, fee caps, versioned hash checks).

### devp2p txpool wire protocol
- `devp2p/caps/eth.md`
  - `Transactions (0x02)`
  - `NewPooledTransactionHashes (0x08)`
  - `GetPooledTransactions (0x09)`
  - `PooledTransactions (0x0a)`
  - Order/size/availability semantics for pooled transaction exchange.

## Nethermind References

### DB layer listing requested (`nethermind/src/Nethermind/Nethermind.Db/`)
Key files to mirror architecturally (idiomatic Zig implementation, not direct translation):
- `IDb.cs` - KV DB interface + metrics/flush surface.
- `IColumnsDb.cs` - column-family style abstraction + batched writes/snapshots.
- `IDbProvider.cs` - named DB accessors (`state`, `code`, `receipts`, `blobTransactions`, etc.).
- `DbProvider.cs` - DI-backed provider implementation.
- `DbNames.cs` - canonical DB name constants.
- `RocksDbSettings.cs` - DB settings object for RocksDB-backed stores.
- `MemDb.cs`, `MemDbFactory.cs`, `InMemoryWriteBatch.cs` - in-memory/test DB implementations.
- `BlobTxsColumns.cs`, `ReceiptsColumns.cs`, `MetadataDbKeys.cs` - column/key namespaces used by higher layers.

### TxPool structure reference (`nethermind/src/Nethermind/Nethermind.TxPool/`)
Notable files for architecture mapping:
- `ITxPool.cs`, `TxPool.cs`, `TxPoolConfig.cs`
- `ITxValidator.cs`, `TxSealer.cs`, `TxNonceTxPoolReserveSealer.cs`
- `INonceManager.cs`, `NonceManager.cs`, `NonceLocker.cs`
- `ITxStorage.cs`, `BlobTxStorage.cs`, `HashCache.cs`, `RetryCache.cs`
- `ITxGossipPolicy.cs`, `SpecDrivenTxGossipPolicy.cs`, `TxBroadcaster.cs`

## Voltaire APIs to Use (no custom duplicate types)
Base path: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

### Primary primitives for txpool implementation
- `primitives.Transaction` (`primitives/Transaction/Transaction.zig`)
  - `TransactionType`, `LegacyTransaction`, `Eip1559Transaction`, `Eip4844Transaction`, `Eip7702Transaction`.
- `primitives.AccessList` (`primitives/AccessList/access_list.zig`)
  - Access-list entry model and gas-cost helpers.
- `primitives.FeeMarket` (`primitives/FeeMarket/fee_market.zig`)
  - EIP-1559 base fee and effective gas price helpers.
- `primitives.GasPrice.GasPrice`
- `primitives.MaxFeePerGas.MaxFeePerGas`
- `primitives.MaxPriorityFeePerGas.MaxPriorityFeePerGas`
- `primitives.BaseFeePerGas.BaseFeePerGas`
- `primitives.Nonce.Nonce`
- `primitives.TransactionHash.TransactionHash`
- `primitives.Address.Address`
- `primitives.Hash.Hash`
- `primitives.Blob` (`primitives/Blob/blob.zig`) for type-3 constants/validation helpers.
- `primitives.Rlp` (`primitives/Rlp/Rlp.zig`) for consensus tx encoding/decoding.
- `primitives.PendingTransactionFilter` for JSON-RPC pending tx filter integration.

## Existing Zig File Context
- Requested path `src/host.zig` does not exist in this repo root.
- Actual host interface file is `guillotine-mini/src/host.zig`.
  - `HostInterface` uses vtable functions:
    - `getBalance`, `setBalance`
    - `getCode`, `setCode`
    - `getStorage`, `setStorage`
    - `getNonce`, `setNonce`
  - Uses Voltaire address primitive (`primitives.Address.Address`).

## Transaction Fixture Paths (`ethereum-tests/`)
Primary txpool-facing fixture directories:
- `ethereum-tests/TransactionTests/ttEIP1559/`
- `ethereum-tests/TransactionTests/ttEIP2930/`
- `ethereum-tests/TransactionTests/ttGasPrice/`
- `ethereum-tests/TransactionTests/ttNonce/`
- `ethereum-tests/TransactionTests/ttWrongRLP/`
- `ethereum-tests/RLPTests/`

Representative fixture files:
- `ethereum-tests/TransactionTests/ttEIP1559/maxFeePerGasOverflow.json`
- `ethereum-tests/TransactionTests/ttEIP1559/maxPriorityFeePerGasOverflow.json`
- `ethereum-tests/TransactionTests/ttEIP2930/accessListAddressGreaterThan20.json`
- `ethereum-tests/TransactionTests/ttEIP2930/accessListStorageOver32Bytes.json`
- `ethereum-tests/TransactionTests/ttWrongRLP/RLPExtraRandomByteAtTheEnd.json`
- `ethereum-tests/TransactionTests/ttWrongRLP/RLPTransactionGivenAsArray.json`

Additional useful vectors:
- `execution-spec-tests/tests/cancun/eip4844_blobs/test_blob_txs.py`
- `execution-spec-tests/tests/cancun/eip4844_blobs/test_blob_txs_full.py`
- `execution-spec-tests/tests/static/state_tests/stEIP2930/transactionCostsFiller.yml`
- `execution-spec-tests/tests/static/state_tests/stEIP1559/transactionIntinsicBug_ParisFiller.yml`

## Implementation Guardrails for Phase-5
- Use Voltaire primitives exclusively for transaction and fee types.
- Reuse existing EVM in `guillotine-mini/src/` (no EVM reimplementation).
- Model architecture after Nethermind TxPool modules, but implement with Zig comptime DI and small testable units.
- Admission validation should align with Cancun `transactions.py` and EIP rules before gossip/ordering.
- Pooled gossip behavior must follow `devp2p/caps/eth.md` message semantics and ordering guarantees.
