# Context — [pass 1/5] phase-4-blockchain (Block Chain Management)

Focused context for implementing block chain management in Zig, using Voltaire primitives and the existing guillotine-mini EVM.

## Goals (`prd/GUILLOTINE_CLIENT_PLAN.md`)
- Phase: `phase-4-blockchain`.
- Goal: manage block chain structure and validation.
- Planned components:
  - `client/blockchain/chain.zig`
  - `client/blockchain/validator.zig`
- Structural reference: `nethermind/src/Nethermind/Nethermind.Blockchain/`.
- Primitive/reference implementation: `voltaire/packages/voltaire-zig/src/blockchain/`.

## Relevant specs (`prd/ETHEREUM_SPECS_REFERENCE.md` + spec files)
- Canonical execution validation flow:
  - `execution-specs/src/ethereum/forks/*/fork.py`
  - `execution-specs/src/ethereum/forks/cancun/fork.py` (`state_transition`, `validate_header`)
  - `execution-specs/src/ethereum/forks/prague/fork.py` (`state_transition`, `validate_header`)
- Formal block finalization semantics:
  - Yellow Paper Section 11 (`yellowpaper/`)
- EIPs directly affecting chain/header validation:
  - `EIPs/EIPS/eip-1559.md` (base fee / fee market header behavior)
  - `EIPs/EIPS/eip-3675.md` (PoS transition, block validity rule changes)
  - `EIPs/EIPS/eip-4399.md` (`PREVRANDAO`/`mixHash` semantics post-merge)
  - `EIPs/EIPS/eip-4844.md` (blob tx + header extension + execution-layer validation)
- Network-level block/header/receipt exchange and fork-id context:
  - `devp2p/caps/eth.md` (`GetBlockHeaders`, `BlockHeaders`, `GetBlockBodies`, `BlockBodies`, `NewBlock`, `GetReceipts`, `Receipts`, `forkid`)

## Nethermind DB inventory (`nethermind/src/Nethermind/Nethermind.Db/`)
Key files for storage boundaries and indexing patterns used by blockchain code:
- `IDb.cs`
- `IColumnsDb.cs`
- `IDbProvider.cs`
- `DbProvider.cs`
- `DbProviderExtensions.cs`
- `DbNames.cs`
- `MetadataDbKeys.cs`
- `ReceiptsColumns.cs`
- `BlobTxsColumns.cs`
- `ReadOnlyDb.cs`
- `ReadOnlyDbProvider.cs`
- `MemDb.cs`
- `MemColumnsDb.cs`
- `CompressingDb.cs`
- `RocksDbSettings.cs`
- `Metrics.cs`

## Voltaire Zig APIs (`/Users/williamcory/voltaire/packages/voltaire-zig/src/`)
- Blockchain module exports (`blockchain/root.zig`):
  - `blockchain.Blockchain`
  - `blockchain.BlockStore`
  - `blockchain.ForkBlockCache`
- Primitives to use directly (`primitives/root.zig`):
  - `primitives.Block`
  - `primitives.BlockHeader`
  - `primitives.BlockBody`
  - `primitives.BlockHash`
  - `primitives.BlockNumber`
  - `primitives.Hash`
  - `primitives.StateRoot`
  - `primitives.Receipt`
  - `primitives.Transaction`
  - `primitives.ForkId`
  - `primitives.Rlp`
  - `primitives.Hex`

## Existing Zig host interface
- Requested path in prompt: `src/host.zig`
- Actual file in repo: `guillotine-mini/src/host.zig`
- `HostInterface` is a vtable adapter for state access:
  - `getBalance` / `setBalance`
  - `getCode` / `setCode`
  - `getStorage` / `setStorage`
  - `getNonce` / `setNonce`
- Nested EVM call handling is internal; host interface remains external state boundary.

## Test fixture paths
- `ethereum-tests/BlockchainTests/`
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `execution-spec-tests/fixtures/` (present; sub-fixtures not populated in this checkout)

## Implementation constraints to carry forward
- No custom duplicate blockchain primitive types; use Voltaire types directly.
- Keep EVM integration through existing guillotine-mini boundaries; do not reimplement EVM.
- Follow Nethermind module separation for chain management vs validation, implemented idiomatically in Zig.
- Use comptime dependency injection for storage/consensus wiring.
