# [pass 1/5] phase-5-txpool (Transaction Pool) - Context

## Phase Goal (`prd/GUILLOTINE_CLIENT_PLAN.md`)
- Phase 5 goal: implement pending transaction pool behavior.
- Planned units:
  - `client/txpool/pool.zig` (admission, storage, replacement, eviction)
  - `client/txpool/sorter.zig` (ordering by effective tip/fee policy)
- Structural reference: `nethermind/src/Nethermind/Nethermind.TxPool/`.

## Relevant Specs (`prd/ETHEREUM_SPECS_REFERENCE.md`)
Phase 5 explicitly maps to:
- EIP-1559 (fee market)
- EIP-2930 (access lists)
- EIP-4844 (blob transactions)

### Concrete spec files read for txpool rules
- `execution-specs/src/ethereum/forks/london/transactions.py`
  - Type-0/1/2 transaction models, intrinsic gas, sender recovery, signing hashes.
- `execution-specs/src/ethereum/forks/cancun/transactions.py`
  - Adds type-3 blob transactions and blob-fee related transaction validation.
- `execution-specs/src/ethereum/forks/prague/transactions.py`
  - Adds newer typed tx handling (including type-4 set-code transaction), useful for forward-compatible txpool type dispatch.
- `execution-specs/src/ethereum/forks/london/fork.py`
  - Inclusion-time checks: sender nonce matching, balance checks, tx processing flow.
- `execution-specs/src/ethereum/forks/cancun/fork.py`
  - Inclusion-time blob constraints and post-Cancun transaction validity hooks.
- `execution-specs/src/ethereum/forks/prague/fork.py`
  - Latest fork-level checks, including tx validation call structure.

### EIP files read for txpool admission semantics
- `EIPs/EIPS/eip-2718.md`
  - Typed transaction envelope and tx type byte space.
- `EIPs/EIPS/eip-155.md`
  - Legacy replay protection and signature `v` rules.
- `EIPs/EIPS/eip-2930.md`
  - Access list transaction format and intrinsic/access-list gas costs.
- `EIPs/EIPS/eip-1559.md`
  - Dynamic fee tx format and `max_fee_per_gas` / `max_priority_fee_per_gas` constraints.
- `EIPs/EIPS/eip-4844.md`
  - Blob tx format, blob fee constraints, and pooled network representation requirements.
- `EIPs/EIPS/eip-3607.md`
  - Reject transactions whose sender has deployed code (EOA-only sender rule).

### devp2p files read for txpool gossip protocol
- `devp2p/caps/eth.md`
  - Transaction exchange lifecycle and messages:
    - `Transactions (0x02)`
    - `NewPooledTransactionHashes (0x08)`
    - `GetPooledTransactions (0x09)`
    - `PooledTransactions (0x0a)`
  - Rules for unknown tx types, peer behavior, and announcement/request flow.

## Nethermind DB Listing (`nethermind/src/Nethermind/Nethermind.Db/`)
Directory inventory captured; key files for architecture boundaries:
- `IDb.cs`
  - Base DB interface (KV access, iterators, metadata hooks).
- `IDbProvider.cs`
  - Named DB access surface (`state`, `code`, `receipts`, `blobTransactions`, etc.).
- `DbProvider.cs`
  - DI-backed resolver for named DB instances.
- `DbNames.cs`
  - Canonical DB name constants.
- `IColumnsDb.cs`
  - Column-family abstraction used by receipts/blob tx storage.
- `BlobTxsColumns.cs`, `ReceiptsColumns.cs`
  - Column identifiers relevant to transaction/receipt persistence.
- `MemDb.cs`, `MemColumnsDb.cs`, `InMemoryWriteBatch.cs`
  - In-memory/testing DB implementations.
- `RocksDbSettings.cs`, `CompressingDb.cs`
  - Persistent DB configuration and implementation concerns.

Additional phase structure reference (not required listing step but relevant):
- `nethermind/src/Nethermind/Nethermind.TxPool/ITxPool.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/TxPool.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/TxPoolConfig.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/ITxValidator.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/NonceManager.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/TxBroadcaster.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/ITxGossipPolicy.cs`
- `nethermind/src/Nethermind/Nethermind.TxPool/SpecDrivenTxGossipPolicy.cs`

## Voltaire APIs (`/Users/williamcory/voltaire/packages/voltaire-zig/src/`)
Top-level modules listed:
- `blockchain/`
- `crypto/`
- `evm/`
- `jsonrpc/`
- `precompiles/`
- `primitives/`
- `state-manager/`

Primary txpool-relevant APIs to use (no custom duplicate types):
- `Primitives.Transaction`
  - Canonical transaction types and typed transaction encoding/signing helpers.
- `Primitives.AccessList`
  - Access-list data model (EIP-2930).
- `Primitives.FeeMarket`
  - EIP-1559 base-fee/effective-fee calculations.
- `Primitives.Nonce`
  - Nonce primitive wrapper.
- `Primitives.TransactionHash`
  - Transaction hash type.
- `Primitives.Address`
  - Address primitive.
- `Primitives.Hash`
  - Hash primitive.
- `Primitives.Blob`
  - Blob transaction related types.
- `Primitives.Rlp`
  - Canonical transaction encoding/decoding.
- `Primitives.PendingTransactionFilter`
  - Pending tx filter primitive for RPC integration.
- `blockchain/Blockchain.zig`
  - Chain context access for fee/nonce policy and canonical head integration.

## Existing EVM Host Interface
Requested path `src/host.zig` is not present at repo root.
Active host interface file:
- `guillotine-mini/src/host.zig`

`HostInterface` shape (vtable-backed):
- `getBalance` / `setBalance`
- `getCode` / `setCode`
- `getStorage` / `setStorage`
- `getNonce` / `setNonce`

Implication for phase 5: txpool validation should consume canonical account state through existing host/state plumbing and reuse existing guillotine-mini execution path rather than reimplementing VM behavior.

## ethereum-tests Directory Listing (fixture paths)
Top-level test directories present:
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

Txpool-focused fixture paths to prioritize:
- `ethereum-tests/TransactionTests/ttAddress`
- `ethereum-tests/TransactionTests/ttData`
- `ethereum-tests/TransactionTests/ttEIP1559`
- `ethereum-tests/TransactionTests/ttEIP2028`
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

## Implementation Notes for Next Pass
- Keep txpool validation fork-aware and type-aware (legacy + typed txs).
- Encode/decode and signature checks should be anchored to Voltaire primitives and execution-spec behavior.
- Gossip behavior must match `devp2p/caps/eth.md` tx exchange semantics.
- Follow Nethermind module boundaries conceptually, but implement with Zig idioms and comptime-friendly composition.
