# Context - [pass 1/5] phase-8-networking (Networking (devp2p))

Focused context for Phase 8 networking implementation. This pass captures required goals, canonical specs, architecture references, Voltaire APIs, existing Zig interfaces, and test fixture locations.

## Phase Goal (PRD)
Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

- Phase: `phase-8-networking`
- Goal: implement devp2p networking for peer communication.
- Planned modules:
  - `client/net/rlpx.zig` (RLPx transport)
  - `client/net/discovery.zig` (discv4/discv5)
  - `client/net/eth.zig` (eth wire protocol)
- Structural reference: `nethermind/src/Nethermind/Nethermind.Network/`

## Relevant Specs (ETHEREUM_SPECS_REFERENCE + direct reads)
Source index: `prd/ETHEREUM_SPECS_REFERENCE.md`

Primary devp2p specs for this phase:
- `devp2p/rlpx.md`
- `devp2p/caps/eth.md`
- `devp2p/caps/snap.md`
- `devp2p/discv4.md`
- `devp2p/discv5/discv5.md`
- `devp2p/discv5/discv5-wire.md`
- `devp2p/discv5/discv5-theory.md`
- `devp2p/discv5/discv5-rationale.md`
- `devp2p/enr.md`
- `devp2p/dnsdisc.md`

Key protocol requirements extracted:
- `devp2p/rlpx.md`: RLPx v5, ECIES auth/auth-ack, ECDH-derived session secrets, framed encrypted transport, MAC verification before decrypt, Snappy after Hello, reject payloads inflating over 16 MiB.
- `devp2p/caps/eth.md`: current doc is `eth/69`; phase target remains `eth/68` compatibility. Status handshake gates all other eth messages. Enforce hard/soft message limits. Fork validation depends on ForkID.
- `devp2p/caps/snap.md`: `snap/1` is a satellite protocol and must run beside `eth`; request/response uses request IDs and proof-carrying ranges.
- `devp2p/discv4.md`: UDP, packet max 1280 bytes, Kademlia `k=16`, endpoint proof required to reduce amplification, ENR request/response extension.
- `devp2p/discv5/discv5.md`: discovery v5.1; encrypted discovery + topic advertisement, algorithm/wire split in companion docs.
- `devp2p/enr.md`: ENR must be sorted unique key/value RLP, max size 300 bytes, v4 identity uses keccak256 + secp256k1 signature semantics.
- `devp2p/dnsdisc.md`: authenticated DNS ENR trees for bootstrap (EIP-1459 path), sequence-protected signed root.

Networking EIPs explicitly referenced by the above specs:
- `EIPs/EIPS/eip-8.md` (forward compatibility rules for devp2p/discovery/RLPx)
- `EIPs/EIPS/eip-778.md` (ENR format)
- `EIPs/EIPS/eip-868.md` (discv4 ENR request/response extension)
- `EIPs/EIPS/eip-1459.md` (DNS discovery)
- `EIPs/EIPS/eip-2124.md` (ForkID compatibility checks)
- `EIPs/EIPS/eip-2464.md` (`eth/65` tx announcement/retrieval pattern used by later eth versions)
- `EIPs/EIPS/eip-2718.md`, `EIPs/EIPS/eip-1559.md`, `EIPs/EIPS/eip-4844.md`, `EIPs/EIPS/eip-4895.md`, `EIPs/EIPS/eip-4788.md`, `EIPs/EIPS/eip-7685.md` (header/tx fields that affect eth message validation rules)

## Nethermind.Db listing (requested inventory)
Directory listed: `nethermind/src/Nethermind/Nethermind.Db/`

Key files noted:
- Interfaces/providers: `IDb.cs`, `IReadOnlyDb.cs`, `IColumnsDb.cs`, `IDbFactory.cs`, `IDbProvider.cs`, `DbProvider.cs`, `ReadOnlyDbProvider.cs`
- In-memory implementations: `MemDb.cs`, `MemColumnsDb.cs`, `InMemoryWriteBatch.cs`, `InMemoryColumnBatch.cs`
- Configuration/pruning: `RocksDbSettings.cs`, `PruningConfig.cs`, `PruningMode.cs`, `IPruningConfig.cs`, `FullPruning/`
- Utilities/columns: `DbExtensions.cs`, `DbNames.cs`, `MetadataDbKeys.cs`, `ReceiptsColumns.cs`, `BlobTxsColumns.cs`, `SimpleFilePublicKeyDb.cs`

Why it matters to phase-8: persistent peer metadata, discovery cache, and fork/network metadata should remain behind explicit DB interfaces similar to Nethermind layering.

## Voltaire APIs (from `/Users/williamcory/voltaire/packages/voltaire-zig/src/`)
Top-level modules:
- `primitives/` (Ethereum/network primitive types)
- `crypto/` (hash/signature/crypto implementations)
- `blockchain/`, `state-manager/`, `evm/`, `jsonrpc/`

Relevant primitives from `primitives/root.zig`:
- Network/session: `NetworkId`, `PeerId`, `PeerInfo`, `NodeInfo`, `ProtocolVersion`, `SyncStatus`
- Wire encoding and byte utilities: `Rlp`, `Bytes`, `Hex`, `Base64`
- Identity/crypto value types: `PublicKey`, `PrivateKey`, `Signature`, `Hash`, `Address`
- ETH status/fork wiring: `ForkId`, `ChainId`, `BlockHash`, `BlockNumber`, `TransactionHash`
- ETH payload types: `BlockHeader`, `BlockBody`, `Transaction`, `Receipt`, `Withdrawal`

Relevant crypto from `crypto/root.zig`:
- `secp256k1` (node identity and signatures)
- `Hash`, `HashAlgorithms`, `Keccak256_Accel`, `SHA256_Accel`
- `aes_gcm` (available utility; RLPx framing specifics still follow devp2p formulas)
- `Crypto` helpers and constant-time utilities

Constraint reminder: use these Voltaire primitives directly; do not define duplicate custom types for peer ID, fork ID, node info, transactions, or hashes.

## Existing Zig Host Interface
Requested read target `src/host.zig` does not exist at repo root.
Actual file: `guillotine-mini/src/host.zig`.

Host summary:
- `HostInterface` is a pointer + vtable boundary with methods for balance/code/storage/nonce.
- Nested EVM calls are handled internally by EVM, not by host callback recursion.
- Networking components should feed validated block/tx data into existing execution paths, not bypass `guillotine-mini` host/EVM boundaries.

## Ethereum Tests directories (requested inventory)
Top-level fixture directories in `ethereum-tests/`:
- `ethereum-tests/ABITests`
- `ethereum-tests/BasicTests`
- `ethereum-tests/BlockchainTests`
- `ethereum-tests/DifficultyTests`
- `ethereum-tests/EOFTests`
- `ethereum-tests/GenesisTests`
- `ethereum-tests/JSONSchema`
- `ethereum-tests/KeyStoreTests`
- `ethereum-tests/LegacyTests`
- `ethereum-tests/PoWTests`
- `ethereum-tests/RLPTests`
- `ethereum-tests/TransactionTests`
- `ethereum-tests/TrieTests`

Protocol-adjacent fixture paths:
- `ethereum-tests/RLPTests/RandomRLPTests`
- `ethereum-tests/TransactionTests/ttWrongRLP`
- `ethereum-tests/BlockchainTests/ValidBlocks`
- `ethereum-tests/BlockchainTests/InvalidBlocks`

Additional networking simulator path present in repo:
- `hive/simulators/devp2p/`

## Architecture mapping notes for implementation
- Mirror Nethermind high-level module seams (`Discovery`, `Rlpx`, `P2P`, protocol manager), but keep Zig implementation idiomatic and comptime-DI friendly.
- Keep each unit small/atomic and independently testable.
- Avoid silent error suppression and minimize allocations in packet decode/encode paths.
