# Phase 4: Block Chain Management — Context & Reference Materials

## Overview

Phase 4 implements block chain management: chain structure, block validation (header + body),
canonical chain tracking, fork choice, and block processing pipeline. This phase bridges the
EVM state integration (Phase 3) with the transaction pool (Phase 5) and Engine API (Phase 7).

**Goal**: Manage the block chain structure and validation.

---

## Current Implementation Status

The `client/blockchain/` directory already contains a substantial implementation:

### Existing Files

| File | Purpose | Status |
|------|---------|--------|
| `client/blockchain/root.zig` | Public API module — re-exports Chain, validators, helpers | Complete |
| `client/blockchain/chain.zig` | Chain management backed by Voltaire Blockchain primitive | Complete |
| `client/blockchain/validator.zig` | Post-merge header validation (PoS constants, base fee, blob fields) | Complete |
| `client/blockchain/local_access.zig` | Local-only block access helpers (no fork-cache) | Complete |
| `client/blockchain/bench.zig` | Benchmarks for putBlock / setCanonicalHead throughput | Complete |

### What's Already Implemented

**Chain management** (`chain.zig` — ~800+ lines):
- `Chain` = `blockchain.Blockchain` (Voltaire primitive)
- `head_hash`, `head_block`, `head_number` — canonical head accessors
- `pending_hash`, `pending_block` — pending block (defaults to head)
- `is_canonical`, `is_canonical_strict`, `is_canonical_or_fetch` — canonicality checks
- `has_block`, `is_fork_block` — existence checks
- `put_block`, `set_canonical_head` — write operations
- `get_block_local`, `get_block_by_number_local`, `get_parent_block_local` — local-only reads
- `parent_header_local` — typed error variant for validation paths
- `block_hash_by_number_local` / `_strict` — EVM BLOCKHASH support (256-block window)
- `last_256_block_hashes_local` — recent block hash collection (spec order)
- `common_ancestor_hash_local` / `_strict` — lowest common ancestor
- `has_canonical_divergence_local` — fork divergence detection
- `canonical_reorg_depth_local`, `candidate_reorg_depth_local` — reorg depth calculation
- Comptime DI helpers: `head_hash_of`, `head_block_of`, `head_number_of`, etc.
- Safe/finalized head helpers: `safe_head_hash_of`, `finalized_head_hash_of`, etc.

**Header validation** (`validator.zig` — ~400+ lines):
- `ValidationError` enum with all relevant error variants
- `HeaderValidationContext` struct (allocator, hardfork, parent_header, TTDs)
- `validate_pos_header_constants` — PoS invariants (difficulty=0, nonce=0, empty ommers, extra_data<=32)
- `check_gas_limit` — gas limit within 1/1024 delta + 5000 minimum
- `calculate_base_fee_per_gas` — EIP-1559 base fee progression
- `validate_blob_fields_for_hardfork` — EIP-4844 blob gas validation (Cancun+)
- `validate_timestamp_strictly_greater` — timestamp ordering
- `validate_post_merge_header` — full post-merge validation pipeline
- `is_post_merge` — TTD-aware merge detection
- `merge_header_validator` — comptime DI merge-aware validator pattern

**Local access** (`local_access.zig` — ~76 lines):
- `get_block_local` — hash-based local-only lookup (uses `@hasDecl` for future Voltaire accessor)
- `get_block_by_number_local` — number-based local-only lookup

### What May Still Need Implementation/Review

1. **Block body validation** — transaction root, receipts root, withdrawals root verification
2. **Full state_transition pipeline** — `state_transition(chain, block)` as in execution-specs
3. **Transaction processing in blocks** — connecting to `client/evm/processor.zig`
4. **Receipt generation and storage** — receipt trie building
5. **Withdrawal processing** — EIP-4895 balance updates
6. **System transaction processing** — beacon root storage (EIP-4788), history storage (Prague)
7. **Block insertion pipeline** — `SuggestBlock` / `Insert` Nethermind pattern
8. **Block finalization events** — `NewHeadBlock`, `BlockAddedToMain` event system
9. **Receipt storage** — persistent receipt storage
10. **Blockhash store** — state-based blockhash storage (Osaka/Prague)

---

## Voltaire Primitives (USE THESE — never create custom types)

### Location: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

**Blockchain module** (`blockchain/`):
- `Blockchain` — main orchestrator (local BlockStore + optional ForkBlockCache)
- `BlockStore` — local storage with canonical chain tracking, orphan management
- `ForkBlockCache` — remote block fetching with FIFO caching

**Primitives** (`primitives/`):
- `Block.Block` — complete block (header + body + hash + size + total_difficulty?)
- `BlockHeader.BlockHeader` — full header struct (all EIPs through Cancun)
  - Constants: `EMPTY_OMMERS_HASH`, `EMPTY_TRANSACTIONS_ROOT`, `EMPTY_RECEIPTS_ROOT`, `EMPTY_WITHDRAWALS_ROOT`
  - Fields include: parent_hash, ommers_hash, beneficiary, state/tx/receipt roots, logs_bloom, difficulty, number, gas_limit, gas_used, timestamp, extra_data, mix_hash, nonce, base_fee_per_gas?, withdrawals_root?, blob_gas_used?, excess_blob_gas?, parent_beacon_block_root?
- `BlockBody.BlockBody` — transactions, ommers (UncleHeader), withdrawals (Withdrawal)
- `Hash.Hash` — 32-byte hash type, `Hash.ZERO`, `Hash.equals()`
- `Address` — 20-byte address, `Address.ZERO_ADDRESS`, `Address.fromHex()`
- `Receipt.Receipt` — transaction receipt with status, gas, logs, bloom
- `Withdrawal` — EIP-4895 withdrawal (index, validator_index, address, amount)
- `BaseFeePerGas` — base fee per gas primitive
- `Blob` — EIP-4844 blob type, `Blob.calculateExcessBlobGas()`
- `Hardfork` — hardfork enum with `isAtLeast()`, `isBefore()`, `hasEIP4844()`
- `GasConstants` — per-opcode gas costs
- `Rlp` — RLP encoding/decoding
- `Hex` — hex encoding/decoding

**State Manager** (`state-manager/`):
- `JournaledState` — journaled state with snapshot/restore
- `StateManager` — world state manager
- `StateCache` — state caching
- `ForkBackend` — fork-based state backend

---

## Nethermind Architecture Reference

### Location: `nethermind/src/Nethermind/Nethermind.Blockchain/`

**Core files**:

| File | Purpose |
|------|---------|
| `IBlockTree.cs` | Interface: chain identity, head tracking, block insertion/suggestion, fork choice, finalization |
| `BlockTree.cs` | Implementation: storage, indexing, head management, corruption recovery |
| `BlockTree.AcceptVisitor.cs` | Visitor pattern for block tree traversal |
| `BlockTree.Initializer.cs` | Startup initialization logic |
| `BlockTreeExtensions.cs` | Extension methods for block tree |
| `BlockhashProvider.cs` | BLOCKHASH opcode support (256-block cache + state store fallback) |
| `BlockhashCache.cs` | Prefetch cache for block hashes |
| `AddBlockResult.cs` | Enum: AlreadyKnown, CannotAccept, UnknownParent, InvalidBlock, Added |
| `InvalidBlockException.cs` | Exception for invalid blocks |
| `InvalidTransactionException.cs` | Exception for invalid transactions |
| `ChainHeadInfoProvider.cs` | Chain head info for external consumers |
| `ChainHeadReadOnlyStateProvider.cs` | Read-only state at chain head |

**Sub-directories**:
| Directory | Key Files |
|-----------|-----------|
| `Blocks/` | `BlockStore.cs`, `IBlockStore.cs`, `BadBlockStore.cs`, `BlockhashStore.cs` |
| `Headers/` | `HeaderStore.cs`, `IHeaderStore.cs`, `IHeaderFinder.cs` |
| `Receipts/` | `PersistentReceiptStorage.cs`, `IReceiptStorage.cs`, `ReceiptsRootCalculator.cs`, `ReceiptsRecovery.cs` |
| `Find/` | `IBlockFinder.cs`, `BlockParameter.cs`, `BlockParameterType.cs` |
| `Spec/` | `ChainHeadSpecProvider.cs` — hardfork spec for best suggested header |
| `Contracts/` | `Contract.cs`, `CallableContract.cs` — system contract calls |
| `Visitors/` | `IBlockTreeVisitor.cs`, `DbBlocksLoader.cs`, `StartupBlockTreeFixer.cs` |
| `Services/` | `HealthHintService.cs` |

**Key Nethermind interfaces**:
```csharp
// IBlockTree - main chain interface
interface IBlockTree {
    Block Head { get; }
    Block Genesis { get; }
    BlockHeader BestSuggestedHeader { get; }
    AddBlockResult Insert(Block block);
    AddBlockResult SuggestBlock(Block block);
    void UpdateMainChain(IReadOnlyList<Block> blocks);
    void ForkChoiceUpdated(Hash256 headHash, Hash256 safeHash, Hash256 finalizedHash);
    bool IsKnownBlock(long number, Hash256 hash);
    bool WasProcessed(long number, Hash256 hash);
    event EventHandler<BlockEventArgs> NewHeadBlock;
    event EventHandler<BlockEventArgs> BlockAddedToMain;
}
```

---

## Execution-Specs Reference (Authoritative)

### Block Validation: `execution-specs/src/ethereum/forks/*/fork.py`

**Key files**:
- Cancun: `execution-specs/src/ethereum/forks/cancun/fork.py`
- Prague: `execution-specs/src/ethereum/forks/prague/fork.py`

### Key Functions

#### `state_transition(chain: BlockChain, block: Block) -> None`
Main entry point for applying a block to the blockchain:
1. Validates header via `validate_header()`
2. Constructs `BlockEnvironment` from header + chain state
3. Calls `apply_body()` to execute transactions
4. Verifies computed roots match header (gas_used, tx_root, state_root, receipt_root, bloom, withdrawals_root, blob_gas_used, requests_hash)
5. Appends block to chain (keeping last 255 blocks)

#### `validate_header(chain: BlockChain, header: Header) -> None`
Verifies block header correctness:
- excess_blob_gas matches calculated value
- gas_used <= gas_limit
- base_fee_per_gas matches EIP-1559 calculation
- timestamp > parent.timestamp
- number == parent.number + 1
- extra_data.length <= 32
- difficulty == 0, nonce == 0 (post-merge)
- ommers_hash == EMPTY_OMMER_HASH
- parent_hash matches parent

#### `apply_body(block_env, transactions, withdrawals) -> BlockOutput`
Executes all transactions and withdrawals:
1. Process system transactions (beacon roots, history storage)
2. Decode and process each transaction
3. Process withdrawals
4. (Prague) Process general-purpose requests
5. Returns BlockOutput with tries, logs, gas used

#### `check_transaction(block_env, block_output, tx) -> (sender, effective_gas_price, blob_hashes, blob_gas)`
Pre-execution transaction validation.

#### `process_transaction(block_env, block_output, tx, index) -> None`
Executes single transaction: charges gas, increments nonce, runs EVM, applies refunds, generates receipt.

#### `calculate_base_fee_per_gas(block_gas_limit, parent_gas_limit, parent_gas_used, parent_base_fee) -> Uint`
EIP-1559 base fee calculation.

#### `calculate_excess_blob_gas(parent_header) -> U64`
EIP-4844 excess blob gas (Cancun: MAX=786432, Prague: MAX=1179648).

#### `check_gas_limit(gas_limit, parent_gas_limit) -> bool`
Gas limit within 1/1024 adjustment factor + >= 5000 minimum.

### Key Data Structures

```python
@dataclass
class BlockChain:
    blocks: List[Block]           # Chain history (last 255 blocks kept)
    state: State                  # Current account state
    chain_id: U64                 # Network identifier

class BlockEnvironment:
    chain_id, state, block_gas_limit, block_hashes,
    coinbase, number, base_fee_per_gas, time,
    prev_randao, excess_blob_gas, parent_beacon_block_root

class BlockOutput:
    transactions_trie, receipts_trie, withdrawals_trie,
    block_logs, block_gas_used, blob_gas_used,
    requests, accounts_to_delete, receipt_keys
```

### Constants

| Constant | Cancun | Prague |
|----------|--------|--------|
| `MAX_BLOB_GAS_PER_BLOCK` | 786,432 | 1,179,648 |
| `BASE_FEE_MAX_CHANGE_DENOMINATOR` | 8 | 8 |
| `ELASTICITY_MULTIPLIER` | 2 | 2 |
| `GAS_LIMIT_ADJUSTMENT_FACTOR` | 1024 | 1024 |
| `GAS_LIMIT_MINIMUM` | 5000 | 5000 |
| `SYSTEM_TRANSACTION_GAS` | 30,000,000 | 30,000,000 |

---

## Existing Zig Implementation Files

### EVM Core (`src/`)
- `src/evm.zig` — EVM orchestrator (state, storage, gas, nested calls)
- `src/frame.zig` — bytecode interpreter (stack, memory, PC)
- `src/hardfork.zig` — hardfork enum and feature flags

### Client (`client/`)
- `client/blockchain/` — chain management (detailed above)
- `client/state/` — world state (account.zig, journal.zig, state.zig)
- `client/evm/` — EVM integration (host_adapter.zig, processor.zig, intrinsic_gas.zig)
- `client/db/` — database abstraction (adapter.zig, memory.zig, rocksdb.zig)
- `client/trie/` — Merkle Patricia Trie (node.zig, trie.zig, hash.zig)
- `client/txpool/` — transaction pool (pool.zig, sorter.zig, policy.zig)
- `client/rpc/` — JSON-RPC server
- `client/engine/` — Engine API
- `client/sync/` — synchronization
- `client/network/` — networking (RLPx)

---

## Test Fixtures

### ethereum-tests/BlockchainTests/

**ValidBlocks/**:
- `bcBlockGasLimitTest` — gas limit validation
- `bcEIP1153-transientStorage` — transient storage in blocks
- `bcEIP1559` — EIP-1559 fee market blocks
- `bcEIP3675` — merge transition blocks
- `bcEIP4844-blobtransactions` — blob transaction blocks
- `bcExample` — basic block examples
- `bcExploitTest` — exploit/edge-case blocks
- `bcForkStressTest` — fork stress testing
- `bcGasPricerTest` — gas pricing blocks
- `bcRandomBlockhashTest` — BLOCKHASH tests
- `bcStateTests` — state-related blocks
- `bcValidBlockTest` — general valid block tests
- `bcWalletTest` — wallet operation blocks

**InvalidBlocks/**:
- `bc4895-withdrawals` — invalid withdrawal blocks
- `bcBlockGasLimitTest` — invalid gas limit blocks
- `bcEIP1559` — invalid EIP-1559 blocks
- `bcEIP3675` — invalid merge blocks
- `bcInvalidHeaderTest` — invalid header fields
- `bcMultiChainTest` — multi-chain validation
- `bcStateTests` — invalid state blocks
- `bcUncleHeaderValidity` — invalid uncle headers
- `bcUncleSpecialTests` — uncle edge cases
- `bcUncleTest` — uncle validation

### execution-spec-tests/fixtures/blockchain_tests/

**ValidBlocks/**:
- `bcBlockGasLimitTest`, `bcEIP1153-transientStorage`, `bcEIP1559`, `bcEIP3675`
- `bcEIP4844-blobtransactions`, `bcExample`, `bcExploitTest`, `bcForkStressTest`
- `bcGasPricerTest`, `bcRandomBlockhashTest`, `bcStateTests`, `bcValidBlockTest`
- `bcWalletTest`

**InvalidBlocks/**:
- `bc4895-withdrawals`, `bcBlockGasLimitTest`, `bcEIP1559`, `bcEIP3675`
- `bcInvalidHeaderTest`, `bcMultiChainTest`, `bcStateTests`
- `bcUncleHeaderValidity`, `bcUncleSpecialTests`, `bcUncleTest`

---

## Key Implementation Patterns

### Comptime Dependency Injection
The existing code uses comptime DI extensively (see `merge_header_validator`, `head_hash_of`, etc.).
New validators and processors should follow this pattern.

### Error Handling
All errors are typed unions — no `catch {}` or silent suppression. Every error variant is explicit
and propagated with `try` or matched in `switch`.

### Local-Only Access
The `local_access.zig` adapter pattern centralizes local-only reads to avoid leaking Voltaire
internals. New read paths should go through similar adapters.

### Voltaire Primitive Usage
The implementation correctly wraps `blockchain.Blockchain` as `Chain` and uses Voltaire types
for all block/header/hash operations. No custom types duplicate Voltaire.

---

## Review Priorities for Pass 1

1. **Correctness**: Does `validator.zig` match `execution-specs/forks/*/fork.py` exactly?
2. **Completeness**: Are all header validation checks from `validate_header()` implemented?
3. **Base fee calculation**: Does `calculate_base_fee_per_gas` handle all edge cases?
4. **Blob validation**: Does `validate_blob_fields_for_hardfork` match spec?
5. **Gas limit check**: Does `check_gas_limit` match the 1/1024 rule exactly?
6. **Missing pieces**: What functions from `fork.py` still need implementation?
7. **Test coverage**: Are all public functions tested? Are edge cases covered?
8. **Performance**: Any unnecessary allocations in hot paths?
