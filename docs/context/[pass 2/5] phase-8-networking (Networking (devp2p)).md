# [pass 2/5] phase-8-networking (Networking (devp2p))

## Phase Goal (from PRD)

Source: `prd/GUILLOTINE_CLIENT_PLAN.md`

- Phase: `phase-8-networking`
- Goal: implement devp2p networking for peer communication.
- Planned components:
  - `client/net/rlpx.zig` (RLPx transport)
  - `client/net/discovery.zig` (discv4/v5)
  - `client/net/eth.zig` (eth protocol)
- Architectural reference target:
  - `nethermind/src/Nethermind/Nethermind.Network/`

## Relevant Specs (from spec map)

Source: `prd/ETHEREUM_SPECS_REFERENCE.md`

Phase 8 points to:
- `devp2p/rlpx.md`
- `devp2p/caps/eth.md`
- `devp2p/caps/snap.md`
- `devp2p/discv4.md`
- `devp2p/discv5/discv5.md`
- `devp2p/enr.md`

### Direct spec notes (read in this pass)

- `devp2p/rlpx.md`
  - RLPx v5 over TCP.
  - ECIES handshake with secp256k1, ECDH-derived `aes-secret` and `mac-secret`.
  - Frame format and MAC update rules are strict; ingress MAC should be verified before decrypting frame components.
  - `Hello` is uncompressed; following messages are Snappy-compressed.
  - Reject decompressed payloads above 16 MiB.

- `devp2p/caps/eth.md`
  - Current protocol version in spec is `eth/69`.
  - ETH session is active only after both sides exchange `Status`.
  - RLPx hard cap is ~16.7 MiB; clients should enforce lower soft caps.
  - Defines tx exchange flow: `NewPooledTransactionHashes`, `GetPooledTransactions`, `PooledTransactions`, `Transactions`.

- `devp2p/caps/snap.md`
  - `snap/1` is a satellite protocol to `eth`, not standalone.
  - State snapshot range retrieval must always respond.
  - If requested state root is unavailable, peer must return an empty reply (not silence).

- `devp2p/discv4.md`
  - UDP protocol with signed packets and 1280-byte max packet size.
  - Kademlia-like table with `k=16`.
  - Endpoint proof requirement: valid recent pong (12h window) before sending amplification-prone responses.
  - Packet set includes `Ping`, `Pong`, `FindNode`, `Neighbors`, `ENRRequest`, `ENRResponse`.

- `devp2p/discv5/discv5.md`
  - Discovery v5.1 overview.
  - Main details split into:
    - `devp2p/discv5/discv5-wire.md`
    - `devp2p/discv5/discv5-theory.md`
    - `devp2p/discv5/discv5-rationale.md`
  - Highlights: encrypted communication, topic advertisement/query support, extensible identity crypto.

- `devp2p/enr.md`
  - ENR canonical RLP: `[signature, seq, k, v, ...]`.
  - Key/value pairs must be sorted and unique.
  - Max encoded ENR size is 300 bytes.
  - Text form is `enr:` + URL-safe base64 without padding.
  - v4 identity uses keccak256(content) + secp256k1 signature.

## Nethermind Reference Inventory (requested listing)

Directory listed: `nethermind/src/Nethermind/Nethermind.Db/`

Key files for cross-cutting networking persistence context:
- `DbNames.cs`
- `DbProvider.cs`
- `IDb.cs`
- `IDbProvider.cs`
- `IColumnsDb.cs`
- `MemDb.cs`
- `ReadOnlyDb.cs`
- `RocksDbSettings.cs`
- `Metrics.cs`
- `MetadataDbKeys.cs`

`DbNames.cs` includes networking-relevant DB names:
- `DiscoveryNodes = "discoveryNodes"`
- `DiscoveryV5Nodes = "discoveryV5Nodes"`
- `PeersDb = "peers"`

## Voltaire APIs (must reuse; no custom duplicates)

Directory listed: `/Users/williamcory/voltaire/packages/voltaire-zig/src/`

Top-level modules:
- `blockchain/`
- `crypto/`
- `evm/`
- `jsonrpc/`
- `precompiles/`
- `primitives/`
- `state-manager/`

From `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/root.zig`, networking-relevant exports:
- `PeerId`
- `PeerInfo`
- `NodeInfo`
- `ProtocolVersion`
- `NetworkId`
- `SyncStatus`
- `Rlp`
- `Base64`
- `Hash`
- `Bytes`
- `Bytes32`
- `PublicKey`
- `PrivateKey`
- `Signature`
- `Address`

From `/Users/williamcory/voltaire/packages/voltaire-zig/src/crypto/root.zig`, networking-relevant exports:
- `secp256k1`
- `Hash`
- `SHA256_Accel`
- `Keccak256_Accel`
- `Crypto`

## Existing Host Interface (resolved path)

Requested path `src/host.zig` does not exist at repo root.

Host interface found and read at:
- `guillotine-mini/src/host.zig`

`HostInterface` pattern summary:
- Struct with `ptr: *anyopaque` and `vtable: *const VTable`.
- Current methods:
  - `getBalance` / `setBalance`
  - `getCode` / `setCode`
  - `getStorage` / `setStorage`
  - `getNonce` / `setNonce`
- This is the reference DI style to mirror for networking interfaces.

## Ethereum Tests Fixture Paths (requested listing)

Directories present under `ethereum-tests/`:
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

## Implementation Focus for Phase 8

- Treat `devp2p/` files above as protocol authority before coding.
- Keep capability/session activation semantics exact (`Status` gating, strict frame/auth rules).
- Keep all networking models typed with Voltaire primitives.
- Follow existing ptr+vtable dependency injection style from `guillotine-mini/src/host.zig`.
- Use Nethermind structure as module-boundary reference only, implemented idiomatically in Zig.
