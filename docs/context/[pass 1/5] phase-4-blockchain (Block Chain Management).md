# Context - [pass 1/5] phase-4-blockchain (Block Chain Management)

Focused context for implementing chain management and block validation in Zig with Voltaire primitives and the existing guillotine-mini EVM boundary.

## Phase Goals (from `prd/GUILLOTINE_CLIENT_PLAN.md`)

- Phase ID: `phase-4-blockchain`
- Goal: manage blockchain structure and block validation.
- Planned units:
  - `client/blockchain/chain.zig`
  - `client/blockchain/validator.zig`
- Structural references:
  - `nethermind/src/Nethermind/Nethermind.Blockchain/`
  - `voltaire/packages/voltaire-zig/src/blockchain/`
- Primary fixture target:
  - `ethereum-tests/BlockchainTests/`

## Relevant Specs (from `prd/ETHEREUM_SPECS_REFERENCE.md` + direct files)

### execution-specs (authoritative EL behavior)

- `execution-specs/src/ethereum/forks/london/fork.py`
  - Base fee and gas limit validation (`calculate_base_fee_per_gas`, `validate_header`).
- `execution-specs/src/ethereum/forks/cancun/fork.py`
  - Post-Shanghai and blob-gas aware state transition and header checks.
- `execution-specs/src/ethereum/forks/prague/fork.py`
  - `state_transition`, `validate_header`, `apply_body`, and `requests_hash` verification.
- `execution-specs/src/ethereum/forks/prague/blocks.py`
  - Prague header schema includes `blob_gas_used`, `excess_blob_gas`, `parent_beacon_block_root`, `requests_hash`.
- `execution-specs/src/ethereum/forks/prague/requests.py`
  - Request extraction and `compute_requests_hash` behavior.

### EIPs (normative deltas used by phase-4 validation)

- `EIPs/EIPS/eip-1559.md`
  - Base fee formula, gas target/elasticity, and gas-limit adjustment bounds.
- `EIPs/EIPS/eip-3675.md`
  - Merge rules: PoS header constants, ommer deprecation, forkchoice event semantics.
- `EIPs/EIPS/eip-4399.md`
  - `mixHash`/`PREVRANDAO` semantics after Merge.
- `EIPs/EIPS/eip-4895.md`
  - `withdrawals` payload object and `withdrawals_root` validity check.
- `EIPs/EIPS/eip-4788.md`
  - `parent_beacon_block_root` header field and pre-tx system call flow.
- `EIPs/EIPS/eip-4844.md`
  - `blob_gas_used`, `excess_blob_gas`, and execution-layer blob gas checks.
- `EIPs/EIPS/eip-2935.md`
  - Parent hash history system call at block start.
- `EIPs/EIPS/eip-7685.md`
  - `requests_hash` commitment over typed EL requests.

### devp2p (wire-level validity constraints)

- `devp2p/caps/eth.md`
  - Header and block validity constraints used during sync/import.
  - Fork-gated header fields:
    - London: `basefee-per-gas`
    - Shanghai: `withdrawals-root`
    - Cancun: `blob-gas-used`, `excess-blob-gas`, `parent-beacon-root`
    - Prague: `requests-hash`
  - Core sync messages: `Status`, `GetBlockHeaders`, `BlockHeaders`, `GetBlockBodies`, `BlockBodies`, `GetReceipts`, `Receipts`.

## Nethermind DB Inventory (requested: `nethermind/src/Nethermind/Nethermind.Db/`)

Key files relevant to storage abstraction and provider layering:

- `IDb.cs`
- `IReadOnlyDb.cs`
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
- `MemDbFactory.cs`
- `CompressingDb.cs`
- `RocksDbSettings.cs`
- `FullPruning/FullPruningDb.cs`
- `Metrics.cs`

Additional architecture reference for phase boundaries (not requested list target, but phase-relevant):

- `nethermind/src/Nethermind/Nethermind.Blockchain/BlockTree.cs`
- `nethermind/src/Nethermind/Nethermind.Blockchain/Blocks/BlockStore.cs`
- `nethermind/src/Nethermind/Nethermind.Blockchain/Headers/HeaderStore.cs`
- `nethermind/src/Nethermind/Nethermind.Blockchain/ReadOnlyBlockTree.cs`

## Voltaire APIs (requested: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`)

Top-level modules observed:

- `blockchain/`
- `primitives/`
- `state-manager/`
- `evm/`

Phase-4 relevant blockchain APIs:

- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/root.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`
  - `Blockchain.init`, `getBlockByHash`, `getBlockByNumber`, `putBlock`, `setCanonicalHead`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig`
  - `BlockStore.init`, `putBlock`, `setCanonicalHead`, `getBlock`, `getBlockByNumber`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/ForkBlockCache.zig`
  - `ForkBlockCache.init`, `getBlockByNumber`, `getBlockByHash`, `nextRequest`, `continueRequest`

Phase-4 relevant primitive types (use these, no custom duplicates):

- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Block/Block.zig` (`Block.Block`)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockHeader/BlockHeader.zig` (`BlockHeader.BlockHeader`)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockBody/BlockBody.zig` (`BlockBody.BlockBody`)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Hash/Hash.zig` (`Hash.Hash`)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/ForkId/ForkId.zig` (`ForkId.ForkId`)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/ChainHead/chain_head.zig` (`ChainHead.ChainHead`)

## Existing Host Interface (requested path vs actual path)

Requested path:

- `src/host.zig` (not present in this repository)

Actual host interface used by guillotine-mini:

- `guillotine-mini/src/host.zig`

Host boundary summary:

- `HostInterface` vtable for external state operations only.
- Methods: `getBalance`, `setBalance`, `getCode`, `setCode`, `getStorage`, `setStorage`, `getNonce`, `setNonce`.
- Nested EVM calls are handled internally by the EVM and do not route through this host interface.

## Test Fixture Paths (requested ethereum-tests directories)

Primary blockchain fixtures:

- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`

Notable phase-4 subdirectories:

- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP1559`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP3675`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP4844-blobtransactions`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcStateTests`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcValidBlockTest`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP1559`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP3675`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bc4895-withdrawals`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcInvalidHeaderTest`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcBlockGasLimitTest`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcUncleHeaderValidity`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcStateTests`

Filler/source side:

- `ethereum-tests/src/BlockchainTestsFiller/`

execution-spec-tests note:

- `execution-spec-tests/fixtures/` exists but is empty in this checkout.
- Blockchain-relevant generated specs/tests currently visible under:
  - `execution-spec-tests/tests/paris/`
  - `execution-spec-tests/tests/shanghai/`
  - `execution-spec-tests/tests/cancun/`
  - `execution-spec-tests/tests/prague/`

## Phase-4 Implementation Notes

- Mirror Nethermind module boundaries at a high level, but keep Zig idiomatic and composable.
- Reuse Voltaire `blockchain` + `primitives` types throughout chain/validator paths.
- Keep validation fork-aware (London -> Shanghai -> Cancun -> Prague fields and rules).
- Keep error handling explicit (no silent catches), and minimize hot-path allocations.
- Keep chain management and block validation as separate, testable units.
