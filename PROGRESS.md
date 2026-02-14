# XVI Progress Report

**Date:** 2026-02-14
**Timestamp:** 17:04 UTC

This report compares the XVI Zig client (`client/`) and Effect-TS client (`client-ts/`) against [Nethermind](https://github.com/NethermindEth/nethermind), a production Ethereum execution client in C#. Both XVI implementations mirror Nethermind's architecture across 11 subsystems (Phases 0-10). Testing and polish phases have not started for either client.

---

## Reference: Nethermind Subsystems

Nethermind ships 48+ modules covering: DB (RocksDB), Merkle Patricia Trie, World State, EVM + Precompiles, Blockchain (block processing, validators, canonical chain), Consensus (Ethash/Clique/AuRa/Merge), TxPool, JSON-RPC (HTTP/WS), Engine API (CL bridge), Networking (devp2p, discv4/v5, DNS discovery, RLPx, eth/68, snap/1), Synchronization (full/fast/snap sync), Config/CLI/Logging, Monitoring/HealthChecks, Serialization (RLP/JSON/SSZ), History/Era1 archives, and L2 support (Optimism, Taiko).

---

## Zig Client (`client/`)

**Stats:** ~27k lines of source across 76 files (11 subsystems)

| Phase | Subsystem | Completeness | What's Done | What's Missing |
|-------|-----------|:------------:|-------------|----------------|
| 0 | DB Abstraction | 90% | Vtable interface, in-memory backend, null backend, read-only overlay, column families, provider registry | RocksDB FFI (stubbed) |
| 1 | Merkle Patricia Trie | 80% | `patricialize()` algorithm matching Python spec, node types (leaf/extension/branch), <32-byte inlining, keccak256 via Voltaire | High-level trie helpers partial |
| 2 | World State | 85% | Generic journal with snapshot/restore, account helpers (EIP-161/684/7610 empty predicates), change tracking (create/update/delete/touch) | Integration with full execution loop |
| 3 | EVM Integration | 75% | Intrinsic gas calculator (all TX types, EIP-3860 init code), TX validation, EIP-1559 fee calculation, host adapter skeleton | Full state execution wiring, host adapter completion |
| 4 | Blockchain | 80% | Chain management via Voltaire Blockchain, head/canonical/reorg helpers, typed validator framework | Block validator logic (stubbed), full block processing |
| 5 | TxPool | 70% | Vtable-based pool interface, admission checks (size/gas/blob/nonce), EIP-1559 sorter, broadcast policy | Core pool data structure, eviction, replacement |
| 6 | JSON-RPC | 65% | Envelope parsing, EIP-1474 error codes, response serializers, eth_chainId, net_version, web3_* methods | State/account query methods, batch executor, HTTP server |
| 7 | Engine API | 30% | Method name constants, vtable skeleton (30+ methods V1-V6), capability exchange types | All payload handlers (newPayload, forkchoiceUpdated, getPayload) |
| 8 | Networking | 50% | RLPx frame structure, Snappy parameter validation | Handshake crypto, peer discovery (discv4/v5), eth/68 protocol, peer management |
| 9 | Sync | 70% | Manager startup planner with feed activation, sync mode flags, full/snap request structures, status helpers | Protocol handlers, actual block fetching |
| 10 | Runner/CLI | 90% | CLI argument parsing (chain-id, network-id, hardfork, trace), genesis JSON loading (mainnet/sepolia/zhejiang), config defaults | Main block processing loop, service wiring |

**Shared EVM engine:** [Guillotine](https://github.com/evmts/guillotine) — full hardfork support Frontier through Prague, 20+ EIPs, 100% ethereum/tests passing.

**Overall: ~70% feature-complete.** Infrastructure layers (DB, state, trie, CLI) are solid. Mid-layers (blockchain, txpool, sync) have data structures and interfaces in place but need execution wiring. Upper layers (Engine API, networking) are early-stage.

---

## Effect-TS Client (`client-ts/`)

**Stats:** ~16k lines of source across 74 modules, ~14k lines of tests (65 test files), 11 benchmarks

| Phase | Subsystem | Completeness | What's Done | What's Missing |
|-------|-----------|:------------:|-------------|----------------|
| 0 | DB Abstraction | 85% | Full Effect.js service (get/put/delete/batch/iterator/snapshot), factory pattern, column families, null/read-only variants | RocksDB backend (stubbed) |
| 1 | Merkle Patricia Trie | 95% | Secured/unsecured variants, nibble expansion, node compression, RLP codec, `patricialize()`, extensive tests + benchmarks | — |
| 2 | World State | 90% | Journaling with snapshot/restore, account model, transaction boundary (rollback/commit), transient storage (EIP-1153) | — |
| 3 | EVM Integration | 70% | TransactionProcessor (pre/post execution), host adapter, intrinsic gas calculator, access list builder, refund calculator, release spec tracking | EvmExecutor is placeholder (bridges to Zig EVM, not wired) |
| 4 | Blockchain | 90% | Block tree (canonical + orphans), fork-choice state machine, genesis validation, header validation, BLOCKHASH cache/store, gas accounting, read-only overlay | — |
| 5 | TxPool | 85% | Mempool service (add/remove/get/iterate), admission validator (gas/balance/nonce/blob), fee-based sorting (EIP-1559 + blob pricing) | Persistence integration, eviction policies |
| 6 | JSON-RPC | 75% | Method dispatcher, request/response parsing, batch support, EIP-1474 + Nethermind error codes, server config | Actual eth_*/engine_* method handlers |
| 7 | Engine API | 30% | Capability exchange (`engine_exchangeCapabilities`), client version, Paris method constants | Payload handling, fork-choice updates |
| 8 | Networking | 20% | RLPx capability negotiation, Snappy compression validation | Full p2p peer management, discovery, eth protocol |
| 9 | Sync | 50% | Full sync request planner (batch splitting for headers/bodies/receipts), per-peer rate limiting | P2P message transport, actual sync execution |
| 10 | Runner/CLI | 20% | Basic CLI argument parsing (--help, --version, start) | Full config system, process lifecycle, service wiring |

**Framework:** Pure Effect.js with dependency injection via `Context.Tag` + `Layer` composition. Every module is a typed service with structured error handling.

**Overall: ~65% feature-complete.** Data layer (trie, state, blockchain, db) is mature with comprehensive tests. EVM integration architecture is solid but awaits Zig EVM wiring. Upper layers (networking, engine, runner) are skeletal.

---

## Side-by-Side Comparison

| Subsystem | Nethermind | Zig Client | Effect-TS Client |
|-----------|:----------:|:----------:|:----------------:|
| DB (persistent storage) | RocksDB | In-memory only | In-memory only |
| Merkle Patricia Trie | Full | 80% | 95% |
| World State + Journal | Full | 85% | 90% |
| EVM Execution | Full | 75% (via Guillotine) | 70% (placeholder) |
| Block Processing | Full | 80% | 90% |
| Consensus (PoW/PoS) | Full (4 engines) | Not started | Not started |
| TxPool | Full | 70% | 85% |
| JSON-RPC | Full (60+ methods) | 65% (3 methods) | 75% (framework only) |
| Engine API | Full | 30% | 30% |
| Networking (devp2p) | Full | 50% | 20% |
| Sync (full/fast/snap) | Full | 70% | 50% |
| CLI + Config | Full | 90% | 20% |
| Monitoring/Metrics | Full | Not started | Not started |
| L2 Support | Optimism, Taiko | Not started | Not started |

### Key Gaps vs Nethermind

Both clients are missing:
- **Consensus engine** — No PoW/PoA/PoS implementation (Nethermind has 4 consensus engines)
- **Persistent storage** — RocksDB backends are stubbed in both
- **Full networking** — Peer discovery, connection management, and wire protocol are incomplete
- **Engine API** — Consensus-layer bridge is skeleton-only
- **Monitoring** — No metrics, health checks, or structured logging
- **Testing and polish** — Neither client has started integration testing against ethereum-tests, execution-spec-tests, or hive. Unit test coverage exists for the Effect-TS client but not for the Zig client.

### Where XVI Leads

- **EVM engine** — Guillotine passes 100% of ethereum/tests (Frontier through Prague), which many production clients still work toward
- **Architecture** — Both clients mirror Nethermind's module boundaries, making the remaining work well-scoped
- **Primitives** — Voltaire provides production-quality types (Address, Block, Transaction, RLP, Crypto, Precompiles) shared across both clients
