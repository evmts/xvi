# Context - [pass 1/5] phase-8-networking (Networking (devp2p))

This file captures the exact references needed to implement Phase 8 networking in small, atomic, testable Zig units.

## Phase Goal (from PRD)
Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

- Goal: implement devp2p networking for peer communication.
- Planned Zig components:
  - `client/net/rlpx.zig` - RLPx handshake/framing/encryption
  - `client/net/discovery.zig` - discv4/discv5 and ENR handling
  - `client/net/eth.zig` - eth capability protocol handling
- Structural reference module: `nethermind/src/Nethermind/Nethermind.Network/`

## Relevant Spec Index (from ETHEREUM_SPECS_REFERENCE)
Source: `prd/ETHEREUM_SPECS_REFERENCE.md`

Phase 8 points to:
- `devp2p/rlpx.md`
- `devp2p/caps/eth.md`
- `devp2p/caps/snap.md`
- `devp2p/discv4.md`
- `devp2p/discv5/discv5.md`
- `devp2p/enr.md`

## Spec Requirements To Preserve

### `devp2p/rlpx.md`
- Protocol version is RLPx v5.
- Handshake uses ECIES + secp256k1 with auth/auth-ack exchange.
- Session secrets derive from static and ephemeral ECDH + nonces.
- Framing uses encrypted header/body plus rolling ingress/egress MAC states.
- After Hello, messages are snappy-compressed and must enforce max uncompressed size (reject >16 MiB).

### `devp2p/caps/eth.md`
- Current document version is eth/69, but Phase 8 target in PRD/spec index is eth/68 compatibility work.
- Status exchange must complete before other eth messages.
- Must enforce message size limits and per-message soft limits.
- Chain sync and transaction exchange are concurrent responsibilities on each peer session.

### `devp2p/caps/snap.md`
- snap/1 runs alongside eth and is not standalone.
- Request/response flow is request-id based and proof-carrying.
- Serving node may cap response size but must still respond per protocol rules.

### `devp2p/discv4.md`
- UDP protocol with 1280-byte packet limit.
- Node identity is secp256k1 public key.
- Endpoint proof and ping/pong recency are required for amplification protection.
- Kademlia-style table behavior is defined around k=16 buckets.

### `devp2p/discv5/discv5.md`
- Protocol version v5.1.
- Record-oriented encrypted discovery with topic advertisement support.
- Depends on companion docs in same folder (`discv5-wire.md`, `discv5-theory.md`, `discv5-rationale.md`).

### `devp2p/enr.md`
- ENR is RLP `[signature, seq, k, v, ...]` with sorted unique keys.
- Max encoded ENR size: 300 bytes.
- v4 identity scheme uses secp256k1 and keccak256-based signing/verification semantics.

## Nethermind DB Reference (requested listing)
Directory listed: `nethermind/src/Nethermind/Nethermind.Db/`

Key files to mirror for storage boundaries and dependency seams:
- `nethermind/src/Nethermind/Nethermind.Db/IDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/IDbProvider.cs`
- `nethermind/src/Nethermind/Nethermind.Db/DbProvider.cs`
- `nethermind/src/Nethermind/Nethermind.Db/MemDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/ReadOnlyDb.cs`
- `nethermind/src/Nethermind/Nethermind.Db/RocksDbSettings.cs`
- `nethermind/src/Nethermind/Nethermind.Db/SimpleFilePublicKeyDb.cs`

## Nethermind Network Structure For Phase 8
Directory: `nethermind/src/Nethermind/Nethermind.Network/`

High-value subareas:
- `Rlpx/` (transport, handshake, framing)
- `P2P/` (session, peer lifecycle, message routing)
- `Discovery/` (discovery message flow and node table interactions)
- `NetworkStorage.cs`, `NodesManager.cs`, `PeerManager.cs`, `ProtocolsManager.cs`

Use this as architectural shape only, then implement idiomatically in Zig with comptime DI.

## Voltaire APIs To Reuse (never custom duplicates)
Root listed: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

Primitives:
- `Primitives.PeerId` (`primitives/PeerId/PeerId.zig`)
- `Primitives.NodeInfo` (`primitives/NodeInfo/NodeInfo.zig`)
- `Primitives.ForkId` (`primitives/ForkId/ForkId.zig`)
- `Primitives.ProtocolVersion` (`primitives/ProtocolVersion/ProtocolVersion.zig`)
- `Primitives.Rlp` (`primitives/Rlp/Rlp.zig`)
- `Primitives.Bytes`, `Primitives.Hash`, `Primitives.PublicKey`, `Primitives.PrivateKey`, `Primitives.Uint`

Crypto:
- `Crypto.secp256k1` (`crypto/secp256k1.zig`)
- `Crypto.Hash` and `Crypto.HashAlgorithms` (`crypto/hash.zig`, `crypto/hash_algorithms.zig`)
- `Crypto.Keccak256_Accel` (`crypto/keccak256_accel.zig`)
- `Crypto.aes_gcm` (`crypto/aes_gcm.zig`)

## Existing Zig Host Interface
Requested path `src/host.zig` does not exist in this repository root.
Actual host interface file reviewed: `guillotine-mini/src/host.zig`.

Key takeaway:
- `HostInterface` is a minimal vtable-based boundary for external state access.
- Nested calls are handled internally by EVM logic, not through host callbacks.
- Networking code should remain layered above this and feed validated protocol data into existing execution/state paths, not bypass EVM semantics.

## Ethereum Tests Directories (fixture inventory)
Directory listing captured from `ethereum-tests/`.

Primary fixture roots:
- `ethereum-tests/BlockchainTests`
- `ethereum-tests/TransactionTests`
- `ethereum-tests/RLPTests`
- `ethereum-tests/TrieTests`
- `ethereum-tests/EOFTests`
- `ethereum-tests/BasicTests`
- `ethereum-tests/DifficultyTests`

Useful subpaths for protocol-adjacent serialization/validation work:
- `ethereum-tests/RLPTests/RandomRLPTests`
- `ethereum-tests/TransactionTests/ttWrongRLP`
- `ethereum-tests/BlockchainTests/ValidBlocks`
- `ethereum-tests/BlockchainTests/InvalidBlocks`

## Implementation Guardrails For Phase 8
- Use Voltaire primitives and crypto only; no duplicate custom protocol types.
- Keep RLPx, discovery, and eth modules separated for testability and composition.
- Use comptime DI seams for IO, clocks, crypto backend wiring, and peer/session policies.
- No silent error suppression (`catch {}` forbidden).
- Preserve allocation discipline: prefer reusable buffers and explicit ownership.
