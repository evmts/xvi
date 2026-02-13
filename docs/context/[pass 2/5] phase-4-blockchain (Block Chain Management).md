# [Pass 2/5] Phase 4: Block Chain Management - Context

## Goal (from `prd/GUILLOTINE_CLIENT_PLAN.md`)

Phase: `phase-4-blockchain`

Primary goal: manage chain structure and block validation.

Planned components:
- `client/blockchain/chain.zig` - canonical chain management, head updates, and reorg handling.
- `client/blockchain/validator.zig` - block/header/body validation.

Reference anchors:
- `nethermind/src/Nethermind/Nethermind.Blockchain/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/`

Primary fixture root:
- `ethereum-tests/BlockchainTests/`

## Relevant Specs (from `prd/ETHEREUM_SPECS_REFERENCE.md` + direct file reads)

### Execution-specs (authoritative EL behavior)

Fork files for block transition and header validation:
- `execution-specs/src/ethereum/forks/frontier/fork.py`
- `execution-specs/src/ethereum/forks/london/fork.py`
- `execution-specs/src/ethereum/forks/paris/fork.py`
- `execution-specs/src/ethereum/forks/shanghai/fork.py`
- `execution-specs/src/ethereum/forks/cancun/fork.py`
- `execution-specs/src/ethereum/forks/prague/fork.py`
- `execution-specs/src/ethereum/forks/osaka/fork.py`

Key function anchors found across these fork files:
- `state_transition(chain, block)`
- `validate_header(chain, header)`
- `apply_body(...)`
- `process_transaction(...)`
- `process_withdrawals(...)` (post-Shanghai)
- `validate_proof_of_work(...)` and `validate_ommers(...)` (pre-Paris)

### Yellow Paper

- `yellowpaper/Paper.tex`
  - `\\section{Block Finalisation}` (`label{ch:finalisation}`)
  - Block-level state root consistency constraints and post-transaction finalization model.

### EIPs relevant to phase-4 block/header validation

- `EIPs/EIPS/eip-1559.md` - base fee and London header constraints.
- `EIPs/EIPS/eip-2718.md` - typed transaction envelope impacts on block body decoding.
- `EIPs/EIPS/eip-2930.md` - access-list tx inclusion semantics.
- `EIPs/EIPS/eip-3675.md` - Merge transition and post-PoW header rules.
- `EIPs/EIPS/eip-4399.md` - `PREVRANDAO` / `mixHash` semantics post-Merge.
- `EIPs/EIPS/eip-4895.md` - withdrawals payload/header root post-Shanghai.
- `EIPs/EIPS/eip-4788.md` - beacon root exposure in execution payload context.
- `EIPs/EIPS/eip-4844.md` - blob gas fields and Cancun header/body rules.
- `EIPs/EIPS/eip-6110.md` - deposit requests integration.
- `EIPs/EIPS/eip-7002.md` - EL triggerable withdrawals requests.
- `EIPs/EIPS/eip-7251.md` - consolidation requests.

### devp2p files with phase-4 relevance

- `devp2p/caps/eth.md` - block/header/body wire exchanges for sync assumptions.
- `devp2p/caps/snap.md` - state sync context (adjacent concern to chain progression).
- `devp2p/rlpx.md` - transport envelope when integrating chain sync later.

## Nethermind References

### Requested listing: `nethermind/src/Nethermind/Nethermind.Db/`

Key files noted:
- `nethermind/src/Nethermind/Nethermind.Db/IDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/IColumnsDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/IReadOnlyDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/IDbProvider.cs`
- `nethermind/src/Nethermind/Nethermind.Db/DbProvider.cs`
- `nethermind/src/Nethermind/Nethermind.Db/DbNames.cs`
- `nethermind/src/Nethermind/Nethermind.Db/PruningConfig.cs`
- `nethermind/src/Nethermind/Nethermind.Db/PruningMode.cs`
- `nethermind/src/Nethermind/Nethermind.Db/CompressingDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/MemDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/MemColumnsDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/ReadOnlyDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/ReadOnlyDbProvider.cs`
- `nethermind/src/Nethermind/Nethermind.Db/BlobTxsColumns.cs`
- `nethermind/src/Nethermind/Nethermind.Db/ReceiptsColumns.cs`
- `nethermind/src/Nethermind/Nethermind.Db/MetadataDbKeys.cs`

### Structural reference for this phase

Key blockchain files noted in `nethermind/src/Nethermind/Nethermind.Blockchain/`:
- `BlockTree.cs`
- `BlockTree.Initializer.cs`
- `BlockTreeOverlay.cs`
- `IBlockTree.cs`
- `ReadOnlyBlockTree.cs`
- `BlockhashCache.cs`
- `GenesisBuilder.cs`
- `IBlockFinalizationManager.cs`
- `ManualFinalizationManager.cs`
- `ReceiptCanonicalityMonitor.cs`

## Voltaire APIs to Reuse (no custom duplicate types)

From `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/`:
- `blockchain.root.BlockStore` (`root.zig` export)
- `blockchain.root.Blockchain` (`root.zig` export)
- `blockchain.root.ForkBlockCache` (`root.zig` export)
- `blockchain.BlockStore` (`BlockStore.zig`)
- `blockchain.Blockchain` (`Blockchain.zig`)
- `blockchain.ForkBlockCache` (`ForkBlockCache.zig`)
- `blockchain.PendingRequest` (`ForkBlockCache.zig`)

Voltaire primitives used by those APIs:
- `primitives.Block.Block`
- `primitives.BlockHeader`
- `primitives.BlockBody`
- `primitives.Hash.Hash`
- `primitives.Address`
- `primitives.Hex`

## Existing Zig Host Interface

Resolved path in this workspace:
- `guillotine-mini/src/host.zig`

`HostInterface` currently exposes:
- `getBalance` / `setBalance`
- `getCode` / `setCode`
- `getStorage` / `setStorage`
- `getNonce` / `setNonce`

Important note in file:
- nested calls are handled inside EVM call flow (`inner_call`), not via this host interface.

## Test Fixture Paths

### Ethereum tests (present)

- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/src/BlockchainTestsFiller/ValidBlocks/`
- `ethereum-tests/src/BlockchainTestsFiller/InvalidBlocks/`

Notable phase-4 directories:
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP1559/`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP3675/`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP4844-blobtransactions/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP1559/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP3675/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bc4895-withdrawals/`

### execution-spec-tests status in this checkout

- `execution-spec-tests/fixtures/` exists but is empty in this workspace.
- Available blockchain-oriented tests currently visible under `execution-spec-tests/tests/` include:
  - `execution-spec-tests/tests/osaka/eip7934_block_rlp_limit/`
  - `execution-spec-tests/tests/prague/eip2935_historical_block_hashes_from_state/`
  - `execution-spec-tests/tests/amsterdam/eip7928_block_level_access_lists/`

## Implementation Guidance for Next Step

- Mirror Nethermind boundaries (`chain` orchestration vs `validator`) but keep Zig-idiomatic ownership and error paths.
- Reuse Voltaire `blockchain` and `primitives` modules directly; do not add duplicate block/header/cache types.
- Treat `execution-specs` `fork.py` behavior as source of truth for block import/validation.
- Keep validation fork-aware (pre-Paris PoW rules vs post-Paris constraints, plus Shanghai/Cancun/Prague additions).
