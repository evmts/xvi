# [pass 2/5] Phase 9 - Synchronization

This context file captures the references needed to implement phase-9 sync work with:
- Voltaire primitives (no custom duplicate types)
- existing guillotine-mini EVM (no EVM reimplementation)
- Nethermind structure as architecture reference, implemented idiomatically in Zig

## Goals (from prd/GUILLOTINE_CLIENT_PLAN.md)
Source: `prd/GUILLOTINE_CLIENT_PLAN.md` (Phase 9, lines 154-165)
- Goal: implement chain synchronization strategies.
- Planned sync components:
  - `client/sync/full.zig` (full sync)
  - `client/sync/snap.zig` (snap sync)
  - `client/sync/manager.zig` (sync coordination)
- Structural reference: `nethermind/src/Nethermind/Nethermind.Synchronization/`.

## Relevant Specs (from prd/ETHEREUM_SPECS_REFERENCE.md)
Source: `prd/ETHEREUM_SPECS_REFERENCE.md` (Phase 9, lines 158-169)
- `devp2p/caps/eth.md` for header/body/receipt exchange.
- `devp2p/caps/snap.md` for state snapshot sync.
- Test references: `hive/` sync tests and integration tests.

## Protocol Files Read

### devp2p eth
- `devp2p/caps/eth.md`
- Key sync message definitions used by phase-9:
  - `Status (0x00)` and fork ID handshake (`EIP-2124`) for session gating.
  - `GetBlockHeaders (0x03)` / `BlockHeaders (0x04)` for header sync.
  - `GetBlockBodies (0x05)` / `BlockBodies (0x06)` for body sync.
  - `GetReceipts (0x0f)` / `Receipts (0x10)` for receipts sync.
  - `BlockRangeUpdate (0x11)` for advertised data availability window.
- Notes relevant to implementation:
  - eth protocol soft limits are size-oriented (recommended 2 MiB for headers/bodies/receipts responses).
  - Sync flow in spec: headers first, then bodies, and receipts for fast/snap style bootstraps.

### devp2p snap
- `devp2p/caps/snap.md`
- Key snap messages for state sync:
  - `GetAccountRange (0x00)` / `AccountRange (0x01)`
  - `GetStorageRanges (0x02)` / `StorageRanges (0x03)`
  - `GetByteCodes (0x04)` / `ByteCodes (0x05)`
  - `GetTrieNodes (0x06)` / `TrieNodes (0x07)`
- Notes relevant to implementation:
  - snap is dependent on eth protocol and must run side-by-side.
  - requests must always be answered; empty answers are valid for missing state roots.
  - responses are request-order preserving with soft byte limits and proof requirements.

### execution-specs and EIPs cross-check paths
These are the execution-rule anchors for block import validation during sync:
- `execution-specs/src/ethereum/forks/paris/fork.py`
- `execution-specs/src/ethereum/forks/shanghai/fork.py`
- `execution-specs/src/ethereum/forks/cancun/fork.py`
- `execution-specs/src/ethereum/forks/prague/fork.py`
- Functions to align with when wiring sync-to-import path: `state_transition`, `validate_header`, `apply_body`, `process_transaction`.

EIP files present and relevant to sync/fork negotiation/history scope:
- `EIPs/EIPS/eip-2124.md` (Fork ID in status)
- `EIPs/EIPS/eip-3675.md` (The Merge)
- `EIPs/EIPS/eip-4444.md` (history serving constraints)
- `EIPs/EIPS/eip-4844.md` (blob tx era effects)
- `EIPs/EIPS/eip-4895.md`, `EIPs/EIPS/eip-4788.md`, `EIPs/EIPS/eip-2935.md` (post-merge execution context)

## Nethermind Architecture References

### Synchronization module (primary structural reference)
- Root: `nethermind/src/Nethermind/Nethermind.Synchronization/`
- Key files/directories reviewed:
  - `Synchronizer.cs`
  - `ParallelSync/SyncMode.cs`
  - `Blocks/BlockDownloadRequest.cs`
  - `Blocks/BlockDownloaderLimits.cs`
  - `FastBlocks/`, `FastSync/`, `SnapSync/`, `StateSync/`, `Peers/`, `ParallelSync/`
- Mapping clues for Zig:
  - startup feed orchestration and lifecycle hooks are in `Synchronizer.Start*`.
  - sync mode bit layout and helper semantics come from `ParallelSync/SyncMode.cs`.
  - peer-specific request limits come from `Blocks/BlockDownloaderLimits.cs`.

### Nethermind DB module (requested directory listing)
Directory listed: `nethermind/src/Nethermind/Nethermind.Db/`

Key files to mirror in boundaries (not code):
- `DbProvider.cs`, `IDbProvider.cs`, `DbProviderExtensions.cs`
- `DbNames.cs`, `MetadataDbKeys.cs`
- `IDb.cs`, `IReadOnlyDb.cs`, `IColumnsDb.cs`, `IFullDb.cs`
- `MemDb.cs`, `MemColumnsDb.cs`, `ReadOnlyDb.cs`, `ReadOnlyColumnsDb.cs`
- `RocksDbSettings.cs`, `CompressingDb.cs`, `NullRocksDbFactory.cs`
- `PruningConfig.cs`, `PruningMode.cs`, `FullPruning/`

Sync-relevant DB names/keys noted:
- DB names include: `Headers`, `Blocks`, `Receipts`, `BlockInfos`, `Metadata`.
- Metadata keys include: beacon pivot hash/number, fast-header barrier keys, receipts/bodies barriers.

## Voltaire APIs (from /Users/williamcory/voltaire/packages/voltaire-zig/src)
Top-level directories listed:
- `blockchain/`, `state-manager/`, `primitives/`, `jsonrpc/`, `evm/`, `crypto/`, `precompiles/`

Relevant exports for sync work:
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/root.zig`
  - `BlockHeader`, `BlockBody`, `BlockNumber`, `Hash`, `Receipt`, `PeerInfo`, `SyncStatus`, `Rlp`, `Hardfork`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/PeerInfo/PeerInfo.zig`
  - peer capability and client-name/caps metadata used for per-peer limit decisions
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/SyncStatus/SyncStatus.zig`
  - canonical sync/not-syncing model for RPC-facing status
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/root.zig`
  - `BlockStore`, `ForkBlockCache`, `Blockchain`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/root.zig`
  - `StateManager`, `JournaledState`, `ForkBackend`

## Existing Zig Files (current phase-9 state)
Sync module currently present:
- `client/sync/root.zig`
- `client/sync/manager.zig`
- `client/sync/full.zig`
- `client/sync/headers.zig`
- `client/sync/mode.zig`
- `client/sync/status.zig`

Observed mismatch with plan target:
- Plan mentions `client/sync/snap.zig`, but this file does not currently exist.

Host interface file read (repository layout note):
- Actual path in this workspace: `guillotine-mini/src/host.zig`
- `HostInterface` uses `ptr + vtable` with methods:
  - `getBalance/setBalance`
  - `getCode/setCode`
  - `getStorage/setStorage`
  - `getNonce/setNonce`
- This is the comptime DI pattern to mirror for sync orchestration interfaces.

## Ethereum Test Fixture Paths
Top-level fixture directories under `ethereum-tests/`:
- `ethereum-tests/BlockchainTests/`
- `ethereum-tests/DifficultyTests/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/EOFTests/`

Sync-relevant fixture subsets:
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/DifficultyTests/`

Additional sync/integration references from specs:
- `hive/` (exists in workspace: `hive/` and `guillotine-mini/hive/`)

## Implementation Notes for Next Pass
- Keep sync data structures on Voltaire primitives only.
- Keep module boundaries Nethermind-like (`manager/full/snap/status/mode`) but idiomatic Zig.
- Continue using comptime DI + vtable patterns used in `guillotine-mini/src/host.zig` and current `client/sync/manager.zig`.
- Preserve explicit error propagation; do not suppress errors.
