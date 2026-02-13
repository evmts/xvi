# Context — [pass 1/5] phase-4-blockchain (Block Chain Management)

Focused context for implementing chain management and block validation in Zig with Voltaire primitives and guillotine-mini.

## Phase goal (`prd/GUILLOTINE_CLIENT_PLAN.md`)
- Phase: `phase-4-blockchain`.
- Goal: manage block chain structure and block validation.
- Planned units:
  - `client/blockchain/chain.zig`
  - `client/blockchain/validator.zig`
- Architecture reference: `nethermind/src/Nethermind/Nethermind.Blockchain/`
- Primitive/runtime reference: `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/`

## Primary spec map (`prd/ETHEREUM_SPECS_REFERENCE.md`)
- Core EL spec source: `execution-specs/` (authoritative).
- Normative deltas: `EIPs/`.
- Wire-level block/header validity constraints: `devp2p/caps/eth.md`.
- Main fixture source for this phase: `ethereum-tests/BlockchainTests/`.

## Execution-spec files to anchor implementation
- `execution-specs/src/ethereum/forks/prague/fork.py`
  - `state_transition`: validates header, executes body, checks roots/gas/bloom/blob gas/requests hash.
  - `validate_header`: parent linkage, monotonic number/timestamp, gas checks, base fee check, post-merge constants.
  - `apply_body`: transaction loop + withdrawals + system transactions + request processing.
- `execution-specs/src/ethereum/forks/cancun/fork.py`
  - Canonical pre-Prague post-Cancun behavior (`blob_gas_used`, `excess_blob_gas`, `parent_beacon_block_root`, withdrawals).
- `execution-specs/src/ethereum/forks/paris/fork.py`
  - Post-merge baseline (difficulty/nonce/ommers constraints, base fee continuity).
- `execution-specs/src/ethereum/forks/prague/requests.py`
  - `compute_requests_hash`, deposit log parsing, EIP-7685 request encoding expectations.
- `execution-specs/src/ethereum/forks/prague/blocks.py`
  - Header/body field set including `requests_hash`.
- `execution-specs/src/ethereum/fork_criteria.py`
  - Fork activation model (`ByBlockNumber`, `ByTimestamp`) for fork-aware validator design.
- `execution-specs/src/ethereum/genesis.py`
  - Genesis header field initialization across fork-dependent optional fields.

## EIPs directly relevant to phase-4 block validation
- `EIPs/EIPS/eip-1559.md`
  - Base fee update rule, gas-limit delta constraints, typed tx interactions.
- `EIPs/EIPS/eip-3675.md`
  - Merge validity changes: PoW removal, `difficulty=0`, zero nonce, empty ommers, extra data limit.
- `EIPs/EIPS/eip-4399.md`
  - `mixHash` -> `prevRandao` semantics and opcode behavior (`PREVRANDAO`).
- `EIPs/EIPS/eip-4895.md`
  - `withdrawals` in block body + `withdrawals_root` header commitment.
- `EIPs/EIPS/eip-4844.md`
  - `blob_gas_used`, `excess_blob_gas`, blob fee/accounting, blob tx block validity.
- `EIPs/EIPS/eip-4788.md`
  - `parent_beacon_block_root` header field + required system call behavior.
- `EIPs/EIPS/eip-2935.md`
  - Historical block hash storage system call (`HISTORY_STORAGE_ADDRESS`).
- `EIPs/EIPS/eip-7685.md`
  - `requests_hash` commitment algorithm (sha256 over non-empty request chunks).
- `EIPs/EIPS/eip-6110.md`
  - Deposit request extraction from logs (request type `0x00`) for block requests list.
- `EIPs/EIPS/eip-7002.md`
  - Withdrawal request system contract (request type `0x01`) and block invalidation conditions.
- `EIPs/EIPS/eip-7251.md`
  - Consolidation request system contract (request type `0x02`) and request queue processing.
- `EIPs/EIPS/eip-7623.md`
  - Calldata floor gas impact on transaction gas accounting in block execution.

## devp2p files relevant to this phase
- `devp2p/caps/eth.md`
  - Block header/body encoding and validity checks for network ingress.
  - Fork-gated header fields (`basefee`, `withdrawals_root`, `blob fields`, `requests_hash`).
  - Message contracts for block data flow: `GetBlockHeaders`, `BlockHeaders`, `GetBlockBodies`, `BlockBodies`, `NewBlock`, `GetReceipts`, `Receipts`.

## Nethermind DB inventory (`nethermind/src/Nethermind/Nethermind.Db/`)
Key files to mirror DB layering, naming, columns, and read-only boundaries:
- `IDb.cs`
- `IColumnsDb.cs`
- `IDbFactory.cs`
- `IDbProvider.cs`
- `DbProvider.cs`
- `DbProviderExtensions.cs`
- `DbNames.cs`
- `MetadataDbKeys.cs`
- `ReceiptsColumns.cs`
- `BlobTxsColumns.cs`
- `ReadOnlyDb.cs`
- `ReadOnlyColumnsDb.cs`
- `ReadOnlyDbProvider.cs`
- `MemDb.cs`
- `MemColumnsDb.cs`
- `CompressingDb.cs`
- `RocksDbSettings.cs`
- `Metrics.cs`

## Voltaire primitives and blockchain APIs
Paths scanned:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/`

Relevant APIs (use these, do not duplicate):
- `blockchain.Blockchain`
- `blockchain.BlockStore`
- `blockchain.ForkBlockCache`
- `primitives.Block`
- `primitives.BlockHeader`
- `primitives.BlockBody`
- `primitives.BlockHash`
- `primitives.BlockNumber`
- `primitives.Hash`
- `primitives.StateRoot`
- `primitives.Receipt`
- `primitives.Transaction`
- `primitives.Withdrawal`
- `primitives.BeaconBlockRoot`
- `primitives.BaseFeePerGas`
- `primitives.FeeMarket`
- `primitives.ForkId`
- `primitives.Rlp`
- `primitives.Hex`

## Existing Zig EVM host boundary
- Prompt path requested: `src/host.zig`.
- Actual file in this repo: `guillotine-mini/src/host.zig`.
- `HostInterface` is a vtable-based external state adapter:
  - `getBalance` / `setBalance`
  - `getCode` / `setCode`
  - `getStorage` / `setStorage`
  - `getNonce` / `setNonce`
- Nested calls are handled inside the EVM; this host stays the chain/state boundary.

## Test fixtures discovered
- `ethereum-tests/BlockchainTests/ValidBlocks/`
  - `bcEIP1559`
  - `bcEIP3675`
  - `bcEIP4844-blobtransactions`
  - `bcStateTests`
  - `bcValidBlockTest`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
  - `bcEIP1559`
  - `bcEIP3675`
  - `bcInvalidHeaderTest`
  - `bcUncleHeaderValidity`
  - `bcStateTests`
- `execution-spec-tests/fixtures/` exists but no deeper fixture directories are populated in this checkout.

## Implementation notes for phase-4
- Implement fork-aware header validation (Paris -> Shanghai -> Cancun -> Prague field gates).
- Keep request/system-call logic explicit and failure-aware (no silent suppression).
- Separate chain storage concerns from validation logic (Nethermind structure, Zig idioms).
- Use comptime dependency injection for store/validator wiring and test doubles.
