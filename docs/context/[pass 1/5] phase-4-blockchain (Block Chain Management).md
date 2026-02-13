# Context — [pass 1/5] phase-4-blockchain (Block Chain Management)

Focused implementation context for chain management and block validation, using Voltaire primitives and the existing guillotine-mini EVM host boundary.

## 1) Phase Goal (from `prd/GUILLOTINE_CLIENT_PLAN.md`)

- Phase: `phase-4-blockchain`
- Goal: manage blockchain structure and block validation.
- Planned units:
  - `client/blockchain/chain.zig`
  - `client/blockchain/validator.zig`
- Architecture reference:
  - `nethermind/src/Nethermind/Nethermind.Blockchain/`
- Voltaire module reference:
  - `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/`

## 2) Spec Map (from `prd/ETHEREUM_SPECS_REFERENCE.md`)

Primary authoritative sources for this phase:
- `execution-specs/` (EL state transition and header/body validation rules)
- `EIPs/` (normative fork deltas)
- `devp2p/` (header/body exchange and compatibility constraints)
- `ethereum-tests/BlockchainTests/` and `execution-spec-tests` (fixtures/tests)

## 3) execution-specs Files To Anchor Validator/Chain Logic

Core fork entrypoints:
- `execution-specs/src/ethereum/forks/paris/fork.py`
  - Post-merge baseline: `state_transition`, `validate_header`, `apply_body`, `check_gas_limit`.
- `execution-specs/src/ethereum/forks/cancun/fork.py`
  - Adds blob gas semantics and beacon root handling in block validation/processing.
- `execution-specs/src/ethereum/forks/prague/fork.py`
  - Adds request commitment flow (`requests_hash`) and extended block processing.
- `execution-specs/src/ethereum/forks/prague/requests.py`
  - Request extraction/formatting + `compute_requests_hash`.
- `execution-specs/src/ethereum/forks/prague/blocks.py`
  - Prague block/header/body schema (`requests_hash` in header).
- `execution-specs/src/ethereum/forks/*/fork_types.py`
  - Canonical account/types used by each fork module.

What matters architecturally:
- `state_transition()` defines full block import checks (header validity, execute body, verify roots/metrics, append chain).
- `validate_header()` defines parent linkage, monotonicity, gas/base-fee checks, and fork-gated field requirements.
- `get_last_256_block_hashes()` indicates minimum historical hash availability expected by execution.

## 4) EIPs Directly Relevant To Block Chain Management

- `EIPs/EIPS/eip-3675.md` (Merge): PoS transition, PoW validation removal, post-merge header constraints.
- `EIPs/EIPS/eip-4399.md`: `DIFFICULTY` opcode semantics -> `PREVRANDAO`; header field semantics shift.
- `EIPs/EIPS/eip-1559.md`: base fee update formula + gas limit elasticity constraints.
- `EIPs/EIPS/eip-2718.md`: typed transaction envelope rules impacting tx/receipt roots.
- `EIPs/EIPS/eip-2930.md`: typed access-list transaction validity and costing.
- `EIPs/EIPS/eip-4895.md`: withdrawals object + `withdrawals_root` commitment.
- `EIPs/EIPS/eip-4844.md`: blob txs, `blob_gas_used`, `excess_blob_gas`, and blob-related block checks.
- `EIPs/EIPS/eip-4788.md`: `parent_beacon_block_root` header field + system-level processing implications.
- `EIPs/EIPS/eip-7685.md`: generalized EL request bus + `requests_hash` commitment algorithm.
- `EIPs/EIPS/eip-6110.md`: deposit requests sourcing from EL logs.
- `EIPs/EIPS/eip-7002.md`: EL-triggered withdrawal request queueing/dequeuing.
- `EIPs/EIPS/eip-7251.md`: consolidation requests and associated request type semantics.

## 5) devp2p References For Chain/Data Validity and Compatibility

- `devp2p/caps/eth.md`
  - Header chain validity constraints for synchronization (parent linkage, gas/bounds, fork-gated fields).
  - Required post-fork header fields:
    - London: `basefee-per-gas`
    - Shanghai: `withdrawals-root`
    - Cancun: `blob-gas-used`, `excess-blob-gas`, `parent-beacon-root`
    - Prague: `requests-hash`
  - Block data-validity checks for tx roots, withdrawals root, and ommer constraints.
  - `Status` + ForkID compatibility context (`eth/64` and EIP-2124 mention).
- `devp2p/rlpx.md`
  - Transport/session layer context for where `eth` capability runs (architectural boundary only).

## 6) Nethermind DB Inventory (requested listing)

Listed from `nethermind/src/Nethermind/Nethermind.Db/`.

Key files for storage boundaries and column/provider layering:
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

## 7) Voltaire APIs and Modules (requested listing)

Top-level modules in `/Users/williamcory/voltaire/packages/voltaire-zig/src/` relevant to this phase:
- `blockchain/`
- `primitives/`
- `state-manager/`
- `evm/`

Blockchain module files:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/root.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/ForkBlockCache.zig`

Relevant Voltaire APIs/types to use (no custom duplicates):
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
- `primitives.Hex`
- `primitives.Rlp`
- `primitives.Hardfork`
- `primitives.ForkTransition`

## 8) Existing Zig Host Boundary (requested `src/host.zig`)

- `src/host.zig` does not exist in this repository root.
- Actual host interface file used by guillotine-mini:
  - `guillotine-mini/src/host.zig`
- Host boundary details:
  - `HostInterface` vtable over external state primitives:
    - `getBalance` / `setBalance`
    - `getCode` / `setCode`
    - `getStorage` / `setStorage`
    - `getNonce` / `setNonce`
  - Nested call execution is handled by EVM internals; this host is an external state adapter boundary.

## 9) Test Fixture Paths

From `ethereum-tests/`:
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
- Filler sources:
  - `ethereum-tests/src/BlockchainTestsFiller/ValidBlocks/`
  - `ethereum-tests/src/BlockchainTestsFiller/InvalidBlocks/`

From `execution-spec-tests/`:
- fixture root present: `execution-spec-tests/fixtures/`
- blockchain-relevant generated test suites currently present under:
  - `execution-spec-tests/tests/paris/`
  - `execution-spec-tests/tests/shanghai/`
  - `execution-spec-tests/tests/cancun/`
  - `execution-spec-tests/tests/prague/`
  - `execution-spec-tests/tests/osaka/`

## 10) Implementation Guidance for Phase-4 (Zig + Nethermind structure)

- Split responsibilities:
  - chain storage/canonicalization/reorg primitives in `chain.zig`
  - header/body validation and fork-gated rule checks in `validator.zig`
- Make fork-aware validation explicit and data-driven (Paris/Shanghai/Cancun/Prague transitions).
- Keep validator side-effect free where possible; inject store/state readers with comptime DI patterns.
- Reuse Voltaire block and primitive types end-to-end.
- Keep error paths explicit (no silent suppression), and isolate hot-path allocations.
