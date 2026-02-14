# [pass 1/5] phase-9-sync (Synchronization) Context

## 1) Phase Goal (from PRD)
Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

- Phase: `phase-9-sync`.
- Goal: implement chain synchronization strategies.
- Planned components:
  - `client/sync/full.zig` (full sync)
  - `client/sync/snap.zig` (snap sync)
  - `client/sync/manager.zig` (sync coordination)
- Structural reference: `nethermind/src/Nethermind/Nethermind.Synchronization/`.

## 2) Relevant Specs (from PRD spec map)
Source: `prd/ETHEREUM_SPECS_REFERENCE.md`

Phase-9 references:
- `devp2p/caps/eth.md` (block/header/receipt exchange)
- `devp2p/caps/snap.md` (snap state sync)
- `hive/` sync tests + integration tests

### 2.1 `devp2p/caps/eth.md` sync-relevant sections
- `## Chain Synchronization`
- `### GetBlockHeaders (0x03)` / `### BlockHeaders (0x04)`
- `### GetBlockBodies (0x05)` / `### BlockBodies (0x06)`
- `### GetReceipts (0x0f)` / `### Receipts (0x10)`
- `### NewBlock (0x07)` / `### NewBlockHashes (0x01)`
- `### BlockRangeUpdate (0x11)`

Summary: header-first download, then bodies/receipts, with request-id based pairing and size limits that should shape batching.

### 2.2 `devp2p/caps/snap.md` sync-relevant sections
- `## Synchronization algorithm`
- `### GetAccountRange (0x00)` / `### AccountRange (0x01)`
- `### GetStorageRanges (0x02)` / `### StorageRanges (0x03)`
- `### GetByteCodes (0x04)` / `### ByteCodes (0x05)`
- `### GetTrieNodes (0x06)` / `### TrieNodes (0x07)`

Summary: snap is state-range oriented; correctness depends on proof handling and interplay with `eth` header sync.

## 3) Nethermind DB inventory
Listed: `nethermind/src/Nethermind/Nethermind.Db/`

Key files to mirror conceptually for storage boundaries used by sync:
- `IDb.cs`, `IReadOnlyDb.cs`, `IColumnsDb.cs`, `IDbProvider.cs`, `IDbFactory.cs`
- `DbProvider.cs`, `ReadOnlyDbProvider.cs`, `ReadOnlyDb.cs`
- `CompressingDb.cs`, `RocksDbSettings.cs`
- `DbNames.cs`, `MetadataDbKeys.cs`, `ReceiptsColumns.cs`, `BlobTxsColumns.cs`
- `MemDb.cs`, `MemColumnsDb.cs`, `NullDb.cs`
- `PruningConfig.cs`, `PruningMode.cs`, `FullPruningTrigger.cs`

## 4) Nethermind Sync architecture (for structural guidance)
Listed: `nethermind/src/Nethermind/Nethermind.Synchronization/`

Key files/subsystems:
- `Synchronizer.cs`, `SyncServer.cs`, `SyncPointers.cs`
- `ParallelSync/SyncDispatcher.cs`, `ParallelSync/SyncFeed.cs`, `ParallelSync/SyncMode.cs`
- `Blocks/BlockDownloader.cs`, `Blocks/FullSyncFeed.cs`
- `FastBlocks/HeadersSyncDownloader.cs`, `FastBlocks/BodiesSyncDownloader.cs`, `FastBlocks/ReceiptsSyncDownloader.cs`
- `SnapSync/SnapSyncDownloader.cs`, `SnapSync/SnapSyncFeed.cs`, `SnapSync/SnapProvider.cs`
- `Peers/SyncPeerPool.cs`, `Peers/PeerInfo.cs`

Summary: clear separation of mode selection, feed scheduling, peer allocation, and protocol-specific downloaders.

## 5) Voltaire APIs available (must reuse)
Listed root: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

Relevant modules:
- `blockchain/`: `Blockchain`, `BlockStore`, `ForkBlockCache`
- `state-manager/`: `StateManager`, `JournaledState`, `ForkBackend`
- `primitives/` (selected sync-relevant exports):
  - `BlockHeader`, `BlockBody`, `BlockHash`, `BlockNumber`
  - `Receipt`, `Transaction`, `Hash`, `Rlp`
  - `PeerId`, `PeerInfo`, `ChainHead`, `SyncStatus`, `ForkId`

Summary: phase-9 data/modeling should stay on Voltaire types; avoid client-local duplicate primitives.

## 6) Existing HostInterface in this repo
Requested path in prompt: `src/host.zig`.
Actual file in this repository: `guillotine-mini/src/host.zig`.

HostInterface summary:
- Vtable-backed host adapter over `*anyopaque`.
- Methods:
  - `getBalance` / `setBalance`
  - `getCode` / `setCode`
  - `getStorage` / `setStorage`
  - `getNonce` / `setNonce`
- Uses Voltaire `Address` type and `u256` values.

## 7) Ethereum test fixture paths
Listed under `ethereum-tests/`:

Primary fixture directories for sync/block import:
- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/TrieTests/`
- `ethereum-tests/TransactionTests/`
- `ethereum-tests/DifficultyTests/`

Fixture archives present:
- `ethereum-tests/fixtures_blockchain_tests.tgz`
- `ethereum-tests/fixtures_general_state_tests.tgz`

Additional integration references:
- `hive/` (sync/network integration scenarios referenced in PRD map)

## 8) Current local sync module status
Present in `client/sync/`:
- `full.zig`
- `headers.zig`
- `manager.zig`
- `mode.zig`
- `snap.zig`
- `status.zig`
- `root.zig`

Summary: planned phase-9 component files already exist; next work should focus on spec conformance, performance, and test expansion rather than file scaffolding.
