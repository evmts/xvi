# Context - [pass 1/5] phase-5-txpool (Transaction Pool)

Focused implementation context for txpool work in Zig using Voltaire primitives and the existing guillotine-mini EVM boundary.

## Phase Goal (`prd/GUILLOTINE_CLIENT_PLAN.md`)

- Phase: `phase-5-txpool`
- Goal: implement pending transaction pool behavior.
- Planned code units:
- `client/txpool/pool.zig`
- `client/txpool/sorter.zig`
- Architecture reference:
- `nethermind/src/Nethermind/Nethermind.TxPool/`

## Relevant Specs (`prd/ETHEREUM_SPECS_REFERENCE.md`)

Phase 5 maps directly to:
- EIP-1559 (fee market)
- EIP-2930 (access lists)
- EIP-4844 (blob transactions)

### execution-specs files read (authoritative tx behavior)

- `execution-specs/src/ethereum/forks/london/transactions.py`
- `execution-specs/src/ethereum/forks/cancun/transactions.py`
- `execution-specs/src/ethereum/forks/prague/transactions.py`

What matters for txpool admission and ordering:
- Typed transaction families and field requirements (legacy, type-1, type-2, type-3; plus newer type-4 in Prague context)
- Intrinsic gas rules and access-list gas accounting
- Sender recovery/signature validity constraints
- Fee-cap/priority-fee constraints that determine inclusion viability

### EIP files read (normative transaction rules)

- `EIPs/EIPS/eip-1559.md`
- Type-2 payload, base-fee interaction, effective gas price (`min(max_priority_fee, max_fee - base_fee)`), ordering guidance (priority-fee then arrival time for ties).
- `EIPs/EIPS/eip-2930.md`
- Type-1 payload, access-list format validation, access-list intrinsic gas (`2400` per address, `1900` per storage key).
- `EIPs/EIPS/eip-4844.md`
- Type-3 payload, non-null `to`, blob fee market (`max_fee_per_blob_gas`), mempool implications.
- Explicit mempool recommendation: apply blob replacement fee bump policy (1.1x minimum bump guidance).

### devp2p txpool protocol files read

- `devp2p/caps/eth.md`
- `devp2p/rlpx.md`
- `devp2p/discv4.md`
- `devp2p/discv5/discv5.md`
- `devp2p/enr.md`

`devp2p/caps/eth.md` txpool-relevant rules:
- Handshake pool sync via `NewPooledTransactionHashes`.
- Request unknown txs via `GetPooledTransactions`.
- Message set:
- `Transactions (0x02)`
- `NewPooledTransactionHashes (0x08)`
- `GetPooledTransactions (0x09)`
- `PooledTransactions (0x0a)`
- Validate txs on receipt for pool acceptability (known type, valid signature, intrinsic gas, sender funds, nonce constraints).
- Do not resend to peers who are known to already have a tx.
- `PooledTransactions` response preserves requested order and may skip unavailable hashes.

## Nethermind Architecture References

### Requested listing: `nethermind/src/Nethermind/Nethermind.Db/`

Key files:
- `BlobTxsColumns.cs`
- `CompressingDb.cs`
- `DbNames.cs`
- `DbProvider.cs`
- `IColumnsDb.cs`
- `IDb.cs`
- `IDbFactory.cs`
- `IDbProvider.cs`
- `IFullDb.cs`
- `MemDb.cs`
- `MemDbFactory.cs`
- `ReadOnlyDb.cs`
- `ReadOnlyDbProvider.cs`
- `RocksDbSettings.cs`

Notes:
- Blob tx storage columns already exist in Nethermind DB layer (`BlobTxsColumns.cs`) and are consumed by txpool blob storage.
- Provider/factory abstractions (`DbProvider.cs`, `IDbProvider.cs`, `IDbFactory.cs`) are the structural pattern for data access boundaries.

### TxPool structure (phase target)

From `nethermind/src/Nethermind/Nethermind.TxPool/`:
- Interfaces/contracts:
- `ITxPool.cs`
- `ITxValidator.cs`
- `ITxPoolConfig.cs`
- `IBlobTxStorage.cs`
- Core implementation:
- `TxPool.cs`
- `NonceManager.cs`
- `TxSealer.cs`
- `TxBroadcaster.cs`
- Result/flow modeling:
- `AcceptTxResult.cs`
- Validation and filtering pipeline:
- `Filters/*.cs`
- Replacement policy:
- `Comparison/CompareReplacedTxByFee.cs` (10% bump for regular tx replacement)
- `Comparison/CompareReplacedBlobTx.cs` (2x bump policy on blob fee dimensions)
- Blob storage path:
- `BlobTxStorage.cs` (full/light/blob-processed records)

## Voltaire APIs (`/Users/williamcory/voltaire/packages/voltaire-zig/src/`)

Top-level modules listed:
- `blockchain/`
- `crypto/`
- `evm/`
- `jsonrpc/`
- `primitives/`
- `state-manager/`

Txpool-relevant exports from `.../primitives/root.zig`:
- `primitives.Transaction`
- `primitives.AccessList`
- `primitives.Blob`
- `primitives.Nonce`
- `primitives.TransactionHash`
- `primitives.Address`
- `primitives.Hash`
- `primitives.Rlp`
- `primitives.Signature`
- `primitives.FeeMarket`
- `primitives.BaseFeePerGas`
- `primitives.MaxFeePerGas`
- `primitives.MaxPriorityFeePerGas`
- `primitives.Gas`
- `primitives.GasPrice`
- `primitives.PendingTransactionFilter`

Concrete Voltaire files read:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/root.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Transaction/Transaction.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/FeeMarket/fee_market.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Nonce/Nonce.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/PendingTransactionFilter/pending_transaction_filter.zig`

Implementation guardrail:
- Reuse Voltaire transaction/fee/nonce/filter primitives directly.
- Do not introduce custom duplicate transaction, fee, hash, nonce, or access-list types.

## Existing Zig Host Interface

Requested path `src/host.zig` is not present at repository root.
Actual file read:
- `guillotine-mini/src/host.zig`

`HostInterface` shape:
- Vtable-backed interface (`ptr` + `vtable`) with:
- `getBalance` / `setBalance`
- `getCode` / `setCode`
- `getStorage` / `setStorage`
- `getNonce` / `setNonce`

Implication:
- Txpool validation that depends on account nonce/balance should use established state/host boundaries.
- Do not reimplement EVM execution or nested-call semantics in txpool.

## Ethereum Test Fixture Paths

Top-level directories listed under `ethereum-tests/`:
- `ethereum-tests/ABITests`
- `ethereum-tests/BasicTests`
- `ethereum-tests/BlockchainTests`
- `ethereum-tests/DifficultyTests`
- `ethereum-tests/EOFTests`
- `ethereum-tests/GenesisTests`
- `ethereum-tests/KeyStoreTests`
- `ethereum-tests/LegacyTests`
- `ethereum-tests/PoWTests`
- `ethereum-tests/RLPTests`
- `ethereum-tests/TransactionTests`
- `ethereum-tests/TrieTests`

Txpool-relevant fixture paths:
- `ethereum-tests/TransactionTests/ttAddress`
- `ethereum-tests/TransactionTests/ttData`
- `ethereum-tests/TransactionTests/ttEIP1559`
- `ethereum-tests/TransactionTests/ttEIP2930`
- `ethereum-tests/TransactionTests/ttEIP3860`
- `ethereum-tests/TransactionTests/ttGasLimit`
- `ethereum-tests/TransactionTests/ttGasPrice`
- `ethereum-tests/TransactionTests/ttNonce`
- `ethereum-tests/TransactionTests/ttRSValue`
- `ethereum-tests/TransactionTests/ttSignature`
- `ethereum-tests/TransactionTests/ttVValue`
- `ethereum-tests/TransactionTests/ttValue`
- `ethereum-tests/TransactionTests/ttWrongRLP`
- `ethereum-tests/RLPTests/RandomRLPTests`
- `ethereum-tests/BlockchainTests/ValidBlocks`
- `ethereum-tests/BlockchainTests/InvalidBlocks`

## Immediate Implementation Guidance

- Keep admission logic split into small filter units (Nethermind-like structure, Zig-idiomatic composition).
- Separate regular tx and blob tx replacement rules.
- Make sorting policy explicit and deterministic (effective tip first, tie-break by arrival/sequence).
- Keep gossip responsibilities separate from validation/storage responsibilities.
- Follow existing comptime DI patterns used by current Zig EVM/host integration code.
