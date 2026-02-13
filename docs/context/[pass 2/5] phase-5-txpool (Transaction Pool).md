# [pass 2/5] Phase 5: Transaction Pool (TxPool) - Implementation Context

## Phase Goal (from PRD)

Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

- Phase: `phase-5-txpool`
- Goal: implement pending transaction pool behavior.
- Planned components:
  - `client/txpool/pool.zig`
  - `client/txpool/sorter.zig`
- Nethermind structural reference: `nethermind/src/Nethermind/Nethermind.TxPool/`

## Relevant Spec References (from PRD spec map)

Source: `prd/ETHEREUM_SPECS_REFERENCE.md`

Phase 5 explicitly calls out:
- EIP-1559 (fee market)
- EIP-2930 (access lists)
- EIP-4844 (blob transactions)

Priority order in PRD:
1. `execution-specs/`
2. `EIPs/`
3. `ethereum-tests/` + `execution-spec-tests/`
4. `devp2p/`

## Authoritative Spec Files To Use First

### execution-specs transaction logic

Core transaction validation/encoding/recovery functions:
- `execution-specs/src/ethereum/forks/berlin/transactions.py`
  - `encode_transaction`, `decode_transaction`, `validate_transaction`, `calculate_intrinsic_cost`, `recover_sender`
- `execution-specs/src/ethereum/forks/london/transactions.py`
  - Adds EIP-1559 type-2 encoding/decoding and fee-market transaction handling.
- `execution-specs/src/ethereum/forks/cancun/transactions.py`
  - Adds EIP-4844 type-3 blob transaction handling and blob-related validation constraints.
- `execution-specs/src/ethereum/forks/prague/transactions.py`
  - Adds type-4 set-code transaction handling (EIP-7702 trajectory), useful for forward-compatible txpool design.

### EIPs

- `EIPs/EIPS/eip-2718.md`
  - Typed transaction envelope and type-byte rules.
- `EIPs/EIPS/eip-2930.md`
  - Access-list tx type (`0x01`) and access-list intrinsic gas components.
- `EIPs/EIPS/eip-1559.md`
  - Fee market tx type (`0x02`), effective fee model, priority fee semantics.
- `EIPs/EIPS/eip-4844.md`
  - Blob tx type (`0x03`), blob fee constraints, txpool/networking implications.
- `EIPs/EIPS/eip-7702.md`
  - Set-code tx type (`0x04`) and authorization-list semantics; relevant for upcoming txpool policy.

### devp2p txpool wire behavior

- `devp2p/caps/eth.md`
  - Transaction exchange model and txpool synchronization.
  - Message set required for txpool gossip:
    - `Transactions (0x02)`
    - `NewPooledTransactionHashes (0x08)`
    - `GetPooledTransactions (0x09)`
    - `PooledTransactions (0x0a)`
  - Key guidance:
    - Do not rebroadcast known txs back to same peer.
    - Validate txs for pool acceptance (signature, intrinsic gas, balance, nonce floor).
    - Pool future-nonce window and replacement policy are client-defined.

## Nethermind Architecture References

### TxPool module (primary structural reference)

Directory: `nethermind/src/Nethermind/Nethermind.TxPool/`

High-value files:
- `ITxPool.cs` - public txpool API surface (counts, per-sender views, submit, known checks, blob retrieval, events).
- `TxPool.cs` - core orchestration and filter pipeline.
- `TxPoolConfig.cs` - operational limits and defaults.
- `NonceManager.cs` - sender nonce reservation/coordination.
- `Filters/FutureNonceFilter.cs` - future-nonce window limit policy.
- `Filters/FeeTooLowFilter.cs` - dynamic fee admission gate.
- `Comparison/CompareReplacedTxByFee.cs` - replacement fee bump logic.
- `Collections/TxDistinctSortedPool.cs` and `Collections/BlobTxDistinctSortedPool.cs` - main pool structures.

Observed Nethermind txpool structure to mirror idiomatically in Zig:
- Pre-hash filters then post-hash filters.
- Separate pools for blob vs non-blob txs.
- Hash-cache short-circuit for duplicate detection.
- Per-sender nonce and gap handling.
- Config-driven limits (size, per-sender windows, blob limits, fee thresholds).

### DB module inventory requested for context

Directory: `nethermind/src/Nethermind/Nethermind.Db/`

Key files:
- `IDb.cs`, `IColumnsDb.cs`, `IReadOnlyDb.cs`, `IDbFactory.cs`, `IDbProvider.cs`
- `DbProvider.cs`, `DbProviderExtensions.cs`, `DbNames.cs`, `DbExtensions.cs`
- `RocksDbSettings.cs`, `MemDb.cs`, `MemColumnsDb.cs`, `NullDb.cs`
- `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`, `ReadOnlyDb.cs`, `ReadOnlyDbProvider.cs`
- `BlobTxsColumns.cs`, `ReceiptsColumns.cs`, `MetadataDbKeys.cs`, `Metrics.cs`

Use this only as architecture boundary reference (not as type/model source).

## Voltaire APIs To Use (No Custom Duplicates)

Base path: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

### Export surface
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/root.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/root.zig`

### Txpool-relevant primitive exports
- `primitives.Transaction`
- `primitives.Transaction.TransactionType`
- `primitives.Transaction.LegacyTransaction`
- `primitives.Transaction.Eip1559Transaction`
- `primitives.Transaction.Eip4844Transaction`
- `primitives.Transaction.Eip7702Transaction`
- `primitives.AccessList`
- `primitives.Authorization`
- `primitives.Blob`
- `primitives.Address`
- `primitives.TransactionHash`
- `primitives.Nonce`
- `primitives.Gas`
- `primitives.GasPrice`
- `primitives.MaxFeePerGas`
- `primitives.MaxPriorityFeePerGas`
- `primitives.BaseFeePerGas`
- `primitives.FeeMarket`
- `primitives.Rlp`
- `primitives.PendingTransactionFilter`

Rule for this phase: always consume these Voltaire types/modules directly; do not recreate equivalent local tx or fee wrapper types.

## Host Interface Context

Requested path `src/host.zig` is not present in this repository root.

Actual host interface used by existing EVM wiring:
- `guillotine-mini/src/host.zig`

Host vtable methods (current contract):
- `getBalance` / `setBalance`
- `getCode` / `setCode`
- `getStorage` / `setStorage`
- `getNonce` / `setNonce`

Related adapter already present:
- `client/evm/host_adapter.zig`

This establishes the expected ptr+vtable dependency-injection pattern to follow for txpool interfaces.

## Existing Zig TxPool Code (Current Baseline)

Directory: `client/txpool/`

Current files:
- `client/txpool/root.zig`
- `client/txpool/pool.zig`
- `client/txpool/sorter.zig`
- `client/txpool/policy.zig`
- `client/txpool/limits.zig`
- `client/txpool/admission.zig`
- `client/txpool/accept_result.zig`
- `client/txpool/handling_options.zig`
- `client/txpool/bench.zig`

Current implemented surface (already present):
- Vtable-style `TxPool` interface and config defaults in `pool.zig`.
- Admission helpers (duplicate precheck, size/gas/nonce/blob-fee constraints).
- Fee-priority sorter helper and policy helpers.
- Result/option parity models (`AcceptTxResult`, `TxHandlingOptions`).
- Unit tests for public helpers across txpool files.

Implication for phase implementation:
- Extend this module incrementally instead of re-creating txpool primitives.
- Maintain comptime/vtable DI style used in existing EVM and txpool code.

## Ethereum Test Fixture Paths

Top-level fixture families under `ethereum-tests/`:
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/BlockchainTests/`
- `ethereum-tests/RLPTests/`
- `ethereum-tests/TrieTests/`
- (others available: `ABITests`, `BasicTests`, `EOFTests`, etc.)

Txpool-focused fixture paths:
- `ethereum-tests/TransactionTests/ttNonce`
- `ethereum-tests/TransactionTests/ttGasPrice`
- `ethereum-tests/TransactionTests/ttGasLimit`
- `ethereum-tests/TransactionTests/ttEIP1559`
- `ethereum-tests/TransactionTests/ttEIP2930`
- `ethereum-tests/TransactionTests/ttWrongRLP`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP1559`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP4844-blobtransactions`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP1559`

## Immediate Implementation Guidance For This Phase

- Keep tx admission pipeline aligned with execution-spec tx validity + devp2p pool validity scope.
- Preserve split handling for non-blob and blob txs (limits and policy differ).
- Keep replacement/nonce-window logic explicit and test-first.
- Use Voltaire transaction and fee primitives end-to-end.
- Keep interfaces vtable-based and injectable, matching existing host/txpool style.
