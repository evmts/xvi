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
- Covers legacy, type-1, and type-2 transaction models and validation (`validate_transaction`, intrinsic gas, sender recovery, signing hashes).
- `execution-specs/src/ethereum/forks/cancun/transactions.py`
- Adds blob transaction model (`BlobTransaction` / type-3), `max_fee_per_blob_gas`, `blob_versioned_hashes`, and updated validation paths.

### EIP files read (normative transaction rules)

- `EIPs/EIPS/eip-1559.md`
- Type-2 payload, effective fee semantics, base fee constraints at inclusion time.
- `EIPs/EIPS/eip-2930.md`
- Type-1 payload, access-list shape checks, and intrinsic access-list gas costs (2400/address, 1900/storage key).
- `EIPs/EIPS/eip-4844.md`
- Type-3 payload, non-nil `to` requirement for blob txs, blob-fee market and blob validity constraints.

### devp2p file read (tx gossip wire protocol)

- `devp2p/caps/eth.md`
- Transaction pool message set:
- `Transactions (0x02)`
- `NewPooledTransactionHashes (0x08)`
- `GetPooledTransactions (0x09)`
- `PooledTransactions (0x0a)`
- Behavioral constraints relevant to txpool implementation:
- do not resend same tx to same peer in a session
- preserve requested hash order in `PooledTransactions`
- empty `Transactions` payload is discouraged

## Nethermind DB Listing (requested inventory)

Listed directory:
- `nethermind/src/Nethermind/Nethermind.Db/`

Key files to keep in mind for storage layering patterns:
- `IDb.cs`
- `IDbProvider.cs`
- `DbProvider.cs`
- `DbNames.cs`
- `IColumnsDb.cs`
- `BlobTxsColumns.cs`
- `ReceiptsColumns.cs`
- `InMemoryWriteBatch.cs`
- `MemDb.cs`
- `MemColumnsDb.cs`
- `ReadOnlyDb.cs`
- `ReadOnlyDbProvider.cs`
- `RocksDbSettings.cs`
- `CompressingDb.cs`

Txpool structure references (phase-specific):
- `nethermind/src/Nethermind/Nethermind.TxPool/ITxPool.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/TxPool.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/TxPoolConfig.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/NonceManager.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/TxBroadcaster.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/ITxValidator.cs`

## Voltaire APIs (`/Users/williamcory/voltaire/packages/voltaire-zig/src/`)

Top-level modules listed:
- `blockchain/`
- `crypto/`
- `evm/`
- `jsonrpc/`
- `precompiles/`
- `primitives/`
- `state-manager/`

Txpool-relevant primitive exports from `.../primitives/root.zig`:
- `primitives.Transaction`
- `primitives.AccessList`
- `primitives.FeeMarket`
- `primitives.Nonce`
- `primitives.TransactionHash`
- `primitives.Address`
- `primitives.Hash`
- `primitives.Blob`
- `primitives.Rlp`
- `primitives.Signature`
- `primitives.Gas`
- `primitives.GasPrice`
- `primitives.BaseFeePerGas`
- `primitives.MaxFeePerGas`
- `primitives.MaxPriorityFeePerGas`
- `primitives.PendingTransactionFilter`

Concrete Voltaire files read:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Transaction/Transaction.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/AccessList/access_list.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/FeeMarket/fee_market.zig`

Rule for this phase: use these Voltaire primitives directly; do not add custom duplicate transaction or fee wrapper types.

## Existing Host Interface

Requested path `src/host.zig` does not exist at repository root.

Actual host interface file:
- `guillotine-mini/src/host.zig`

`HostInterface` (vtable/DI pattern) methods:
- `getBalance` / `setBalance`
- `getCode` / `setCode`
- `getStorage` / `setStorage`
- `getNonce` / `setNonce`

Implication: txpool validation should query canonical account state via existing host/state plumbing and reuse guillotine-mini execution behavior, not reimplement EVM behavior.

## Ethereum Test Fixture Paths

Directory families listed under `ethereum-tests/`:
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

Txpool-focused fixture paths:
- `ethereum-tests/TransactionTests/ttAddress`
- `ethereum-tests/TransactionTests/ttData`
- `ethereum-tests/TransactionTests/ttEIP1559`
- `ethereum-tests/TransactionTests/ttEIP2930`
- `ethereum-tests/TransactionTests/ttGasLimit`
- `ethereum-tests/TransactionTests/ttGasPrice`
- `ethereum-tests/TransactionTests/ttNonce`
- `ethereum-tests/TransactionTests/ttRSValue`
- `ethereum-tests/TransactionTests/ttSignature`
- `ethereum-tests/TransactionTests/ttVValue`
- `ethereum-tests/TransactionTests/ttValue`
- `ethereum-tests/TransactionTests/ttWrongRLP`
- `ethereum-tests/RLPTests/RandomRLPTests`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP1559`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP4844-blobtransactions`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP1559`

## Implementation Notes for Next Step

- Keep admission and replacement logic fork-aware and transaction-type aware (legacy/type-1/type-2/type-3).
- Match execution-spec validation boundaries for txpool checks and devp2p gossip semantics.
- Follow Nethermind module boundaries conceptually, but keep Zig idiomatic with small, testable, DI-friendly units.
