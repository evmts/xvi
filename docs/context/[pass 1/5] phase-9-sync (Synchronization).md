# [pass 1/5] phase-9-sync (Synchronization) Context

## Phase 9 goals from PRD
Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

- Goal: implement chain synchronization strategies.
- Planned components:
  - `client/sync/full.zig` for full sync.
  - `client/sync/snap.zig` for snap sync.
  - `client/sync/manager.zig` for sync coordination.
- Structural reference: `nethermind/src/Nethermind/Nethermind.Synchronization/`.
- Design constraints called out in PRD:
  - Use Voltaire primitives.
  - Use guillotine-mini EVM (no reimplementation).
  - Mirror Nethermind module boundaries, implement idiomatically in Zig.
  - Prefer comptime dependency injection and explicit errors.

## Relevant specifications for phase-9
Source: `prd/ETHEREUM_SPECS_REFERENCE.md`

- `devp2p/caps/eth.md` (block/header/receipt exchange over `eth/*`).
- `devp2p/caps/snap.md` (`snap/1` state synchronization).
- Phase reference tests: `hive/` sync tests and integration tests.

### Notes from `devp2p/caps/eth.md`
- Session starts with `Status (0x00)` before other `eth` messages.
- Header/body/receipt pipeline messages used by sync:
  - `GetBlockHeaders (0x03)` / `BlockHeaders (0x04)`
  - `GetBlockBodies (0x05)` / `BlockBodies (0x06)`
  - `GetReceipts (0x0f)` / `Receipts (0x10)`
- `NewBlockHashes (0x01)` and `BlockRangeUpdate (0x11)` are relevant for near-head tracking.
- Current protocol changelog includes `eth/69` updates for range signaling.

### Notes from `devp2p/caps/snap.md`
- Current snap protocol version is `snap/1`.
- State sync request/response pairs:
  - `GetAccountRange (0x00)` / `AccountRange (0x01)`
  - `GetStorageRanges (0x02)` / `StorageRanges (0x03)`
  - `GetByteCodes (0x04)` / `ByteCodes (0x05)`
  - `GetTrieNodes (0x06)` / `TrieNodes (0x07)`
- The document defines expected reconstruction workflow and `eth` relation for headers/proofs.

## Nethermind DB directory snapshot
Listed directory: `nethermind/src/Nethermind/Nethermind.Db/`

Key files observed (for storage abstractions used by sync subsystems):
- Interfaces:
  - `IDb.cs`, `IReadOnlyDb.cs`, `IFullDb.cs`, `IColumnsDb.cs`, `IDbFactory.cs`, `IDbProvider.cs`, `IReadOnlyDbProvider.cs`, `IMergeOperator.cs`
- Provider and wrappers:
  - `DbProvider.cs`, `ReadOnlyDbProvider.cs`, `ReadOnlyDb.cs`, `CompressingDb.cs`, `DbExtensions.cs`, `DbProviderExtensions.cs`
- Implementations:
  - `MemDb.cs`, `MemColumnsDb.cs`, `NullDb.cs`, `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`
- Config and tuning:
  - `RocksDbSettings.cs`, `PruningConfig.cs`, `PruningMode.cs`, `FullPruningTrigger.cs`, `FullPruningCompletionBehavior.cs`
- Column/key metadata:
  - `DbNames.cs`, `MetadataDbKeys.cs`, `ReceiptsColumns.cs`, `BlobTxsColumns.cs`

## Nethermind synchronization architecture to mirror
Reference directory: `nethermind/src/Nethermind/Nethermind.Synchronization/`

Key files and roles:
- `Synchronizer.cs`: top-level coordinator that starts/stops feed components based on sync config/mode.
- `ParallelSync/SyncDispatcher.cs`: generic dispatch loop (`feed + allocator + downloader`) with concurrency and peer allocation.
- `Blocks/FullSyncFeed.cs`: full-sync feed activation and request/response bridge.
- `SnapSync/SnapSyncDownloader.cs`: dispatches snap requests (`GetAccountRange`, `GetStorageRange`, `GetByteCodes`, `GetTrieNodes`) to snap peer protocol.
- `SyncServer.cs`: serves sync requests and gossips new ranges/blocks to peers.
- `Peers/SyncPeerPool.cs` and `Peers/PeerInfo.cs`: sync peer inventory and scoring/allocation surfaces.

## Voltaire APIs relevant to phase-9
Listed source root: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

Primary APIs to reuse:
- Primitives (`primitives/root.zig` exports):
  - `primitives.BlockHeader`, `primitives.BlockBody`, `primitives.BlockHash`, `primitives.BlockNumber`
  - `primitives.Receipt`, `primitives.Transaction`, `primitives.Hash`, `primitives.Rlp`
  - `primitives.PeerId`, `primitives.PeerInfo`, `primitives.ChainHead`, `primitives.ForkId`, `primitives.SyncStatus`
- Blockchain module:
  - `blockchain.Blockchain`, `blockchain.BlockStore`, `blockchain.ForkBlockCache`
- State manager module:
  - `state-manager.StateManager`, `state-manager.JournaledState`, `state-manager.ForkBackend`

These cover canonical types and avoid custom duplicates for sync data structures.

## Existing Zig code in this repo (phase-9 relevant)

### Host interface (requested `src/host.zig` equivalent)
- Actual file in this repo: `guillotine-mini/src/host.zig`.
- `HostInterface` is a vtable-based adapter over `*anyopaque` with methods:
  - `getBalance`, `setBalance`
  - `getCode`, `setCode`
  - `getStorage`, `setStorage`
  - `getNonce`, `setNonce`
- Host uses Voltaire `Address` and builtin `u256`.

### EVM/host bridge already present
- `client/evm/host_adapter.zig` adapts Voltaire `StateManager` to guillotine-mini `HostInterface`.
- Uses fail-fast handling for state errors and test coverage for all host methods.

### Existing sync module status
- `client/sync/root.zig` exports:
  - `BlocksRequest` and per-peer limits from `client/sync/full.zig`
  - `SyncMode` from `client/sync/mode.zig`
  - `HeadersRequest` from `client/sync/headers.zig`
  - `to_sync_status` helpers from `client/sync/status.zig`
- Existing files:
  - `client/sync/full.zig`
  - `client/sync/headers.zig`
  - `client/sync/mode.zig`
  - `client/sync/status.zig`
  - `client/sync/root.zig`
- Gap vs PRD plan:
  - `client/sync/snap.zig` not present.
  - `client/sync/manager.zig` not present (`mode.zig` exists, but not a coordinator implementation).

## Ethereum-tests directories and fixture paths
Listed under `ethereum-tests/`:

Core sync-adjacent fixture directories:
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcStateTests/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcStateTests/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/TransactionTests/`

Useful packaged fixture archives in repo:
- `ethereum-tests/fixtures_blockchain_tests.tgz`
- `ethereum-tests/fixtures_general_state_tests.tgz`

Additional phase reference test source:
- `hive/` (sync/integration scenarios referenced by PRD spec map).

## Implementation-ready checklist for next pass
- Build a `client/sync/manager.zig` coordinator shaped like Nethermind `Synchronizer + SyncDispatcher` roles, but with Zig comptime DI.
- Add `client/sync/snap.zig` request/response containers aligned to `snap/1` message families.
- Keep all sync payload types on Voltaire primitives (`BlockHeader`, `Hash`, `PeerInfo`, `SyncStatus`).
- Preserve explicit error propagation; do not add silent `catch {}` paths.
- Add unit tests for each public function introduced in new sync modules.
