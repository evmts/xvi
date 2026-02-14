# XVI Progress Report

**Date:** 2026-02-14
**Timestamp:** 22:30 UTC

This report compares the XVI Zig client (`client/`) and Effect-TS client (`client-ts/`) against [Nethermind](https://github.com/NethermindEth/nethermind), a production Ethereum execution client in C#. Both XVI implementations mirror Nethermind's architecture across 11 subsystems (Phases 0-10). Testing and polish phases have not started for either client.

---

## Recent Work (since last report)

The most recent development cycle focused on hardening Phases 4-9 of the Zig client with bug fixes, spec compliance improvements, and new features:

- **Phase 4 — Blockchain:** Gas limit delta bounds fixed to exclusive per spec; strict canonicality helper; fork boundary detection; common ancestor split into nullable/strict APIs; BLOCKHASH spec-total helper; dead code removed; 117+ tests
- **Phase 5 — TxPool:** Blob-specific pending lookup API; hash-cache duplicate filter; EIP-7702 benchmark fixes; fee sort comparator fix; vtable test deduplication; effective fee market helper
- **Phase 6 — JSON-RPC:** Batch request executor with size cap; single-request dispatch router; `web3_sha3` (keccak256) method; shared last-key scanner; buffer reuse for batch parsing; parse error classification
- **Phase 7 — Engine API:** Fork-aware capabilities provider (Paris through Osaka); newPayload hash param validation; BlobsBundle cardinality constraints; Prague executionRequests ordering; getPayloadBodies null placeholder support; v3+ method test coverage
- **Phase 8 — Networking:** EIP-8 auth/ack RLP body decoders; handshake size-prefix decoder; fixed handshake buffer; negative error path tests; benchmark extraction; test naming normalization
- **Phase 9 — Sync:** Snap StorageRangeRequest container; BlocksRequest receipt_hashes helper; storage range validation (empty list, zero limit); u64 response_bytes; startup feed sequence helper
- **Workflow:** Switched from Codex CLI to Claude CLI agents

---

## Reference: Nethermind Subsystems

Nethermind ships 48+ modules covering: DB (RocksDB), Merkle Patricia Trie, World State, EVM + Precompiles, Blockchain (block processing, validators, canonical chain), Consensus (Ethash/Clique/AuRa/Merge), TxPool, JSON-RPC (HTTP/WS), Engine API (CL bridge), Networking (devp2p, discv4/v5, DNS discovery, RLPx, eth/68, snap/1), Synchronization (full/fast/snap sync), Config/CLI/Logging, Monitoring/HealthChecks, Serialization (RLP/JSON/SSZ), History/Era1 archives, and L2 support (Optimism, Taiko).

---

## Zig Client (`client/`)

**Stats:** ~30k lines of source across 76 files (11 subsystems)

| Phase | Subsystem | Completeness | What's Done | What's Missing |
|-------|-----------|:------------:|-------------|----------------|
| 0 | DB Abstraction | 90% | Vtable interface, in-memory backend (788 LOC), null backend, read-only overlay, column families, provider registry, adapter layer | RocksDB FFI (stubbed at 324 LOC) |
| 1 | Merkle Patricia Trie | 80% | `patricialize()` algorithm matching Python spec, node types (leaf/extension/branch), <32-byte inlining, keccak256 via Voltaire, benchmarks | High-level trie helpers partial |
| 2 | World State | 85% | Generic journal with snapshot/restore (740 LOC), account helpers (EIP-161/684/7610 empty predicates), change tracking (create/update/delete/touch), journal ops | Integration with full execution loop |
| 3 | EVM Integration | 80% | Intrinsic gas calculator (all TX types incl. EIP-7702), TX validation, EIP-1559 fee calculation, EIP-7623 calldata floor gas (Prague+), `preprice_transaction` batch validation, host adapter skeleton, 40+ tests | Full state execution wiring, balance/nonce checks, receipt generation |
| 4 | Blockchain | 85% | Chain management via Voltaire Blockchain (3,075 LOC), head/canonical/reorg helpers, typed validator framework, strict canonicality, fork boundary detection, BLOCKHASH spec-total helper, common ancestor (nullable + strict), 117+ tests | Block insertion/reorg logic, state root computation |
| 5 | TxPool | 75% | Vtable-based pool interface (12 methods), admission checks (size/gas/blob/nonce), EIP-1559 sorter, broadcast policy, blob-specific lookup, hash-cache duplicate filter, handling options, limits | Core pool data structure implementation, eviction, replacement |
| 6 | JSON-RPC | 75% | Envelope parsing, EIP-1474 error codes, response serializers, batch executor with size cap, single-request dispatch router, `eth_chainId`, `net_version`, `web3_clientVersion`, `web3_sha3`, shared scanner, 100+ tests | eth_* state/account query methods (eth_getBalance, eth_call, etc.), HTTP/WS server transport |
| 7 | Engine API | 55% | Full type definitions (V1-V6), vtable interface (20+ handlers), request/response param types, fork-aware capabilities provider (Paris-Osaka), BlobsBundle cardinality constraints, executionRequests validation, 77 tests | All handler implementations (newPayload, forkchoiceUpdated, getPayload are type-complete but logic-stubbed) |
| 8 | Networking | 55% | RLPx frame encode/decode, EIP-8 auth/ack handshake decoders, size-prefix decoder, secret derivation (ECDH+KDF), MAC state init, Snappy guards, benchmarks, 18+ tests | Handshake state machine execution, peer discovery (discv4/v5), eth/68 protocol, peer management, network I/O |
| 9 | Sync | 70% | Manager startup planner with feed activation, sync mode flags, full/snap request structures, StorageRangeRequest, BlocksRequest receipt_hashes, status helpers, validation guards | Protocol handlers, actual block/state fetching, feed implementations |
| 10 | Runner/CLI | 90% | CLI argument parsing (chain-id, network-id, hardfork, trace), genesis JSON loading (mainnet/sepolia/zhejiang), config defaults | Main block processing loop, service wiring |

**Shared EVM engine:** [Guillotine](https://github.com/evmts/guillotine) — full hardfork support Frontier through Prague, 20+ EIPs, 100% ethereum/tests passing.

**Overall: ~75% feature-complete.** Infrastructure layers (DB, state, trie, CLI) are solid. Mid-layers (blockchain, txpool, EVM integration) have matured with comprehensive validation logic and tests. The Engine API type system is now complete (all versions V1-V6) though handler logic remains stubbed. Networking has usable RLPx protocol primitives but no peer management. The critical gap is end-to-end wiring: no subsystem can yet execute a full block or sync from the network.

---

## Effect-TS Client (`client-ts/`)

**Stats:** ~16k lines of source across 76 modules, ~14k lines of tests (65 test files), 11 benchmarks

| Phase | Subsystem | Completeness | What's Done | What's Missing |
|-------|-----------|:------------:|-------------|----------------|
| 0 | DB Abstraction | 85% | Full Effect.js service (get/put/delete/batch/iterator/snapshot), factory pattern, column families, null/read-only variants, 15+ test files | RocksDB backend (stubbed) |
| 1 | Merkle Patricia Trie | 95% | Secured/unsecured variants, nibble expansion, node compression, RLP codec, `patricialize()`, NodeLoader, NodeStorage, extensive tests + benchmarks | — |
| 2 | World State | 90% | Journaling with snapshot/restore, account model, transaction boundary (rollback/commit), transient storage (EIP-1153), WorldStateReader | — |
| 3 | EVM Integration | 70% | TransactionProcessor (pre/post execution), host adapter, intrinsic gas calculator, access list builder, refund calculator, release spec tracking, TransactionEnvironmentBuilder | EvmExecutor is placeholder (bridges to Zig EVM, not wired) |
| 4 | Blockchain | 90% | Block tree (canonical + orphans), fork-choice state machine, genesis validation, header validation, BLOCKHASH cache/store, gas accounting, read-only overlay, 7 test files | — |
| 5 | TxPool | 85% | Mempool service (add/remove/get/iterate), admission validator (gas/balance/nonce/blob), fee-based sorting (EIP-1559 + blob pricing), 3 test files | Persistence integration, eviction policies |
| 6 | JSON-RPC | 75% | Method dispatcher, request/response parsing, batch support, EIP-1474 + Nethermind error codes, server config, 5 test files | Actual eth_*/engine_* method handlers, HTTP server |
| 7 | Engine API | 30% | Capability exchange (`engine_exchangeCapabilities`), client version, Paris method constants | Payload handling, fork-choice updates |
| 8 | Networking | 20% | RLPx capability negotiation, Snappy compression validation | Full p2p peer management, discovery, eth protocol |
| 9 | Sync | 50% | Full sync request planner (batch splitting for headers/bodies/receipts), per-peer rate limiting | P2P message transport, actual sync execution |
| 10 | Runner/CLI | 20% | Basic CLI argument parsing (--help, --version, start), RunnerMain/RunnerConfig | Full config system, process lifecycle, service wiring |

**Framework:** Pure Effect.js with dependency injection via `Context.Tag` + `Layer` composition. Every module is a typed service with structured error handling.

**Overall: ~65% feature-complete.** Data layer (trie, state, blockchain, db) is mature with comprehensive tests. EVM integration architecture is solid but awaits Zig EVM wiring. Upper layers (networking, engine, runner) are skeletal. No changes in this development cycle — focus has been on the Zig client.

---

## Side-by-Side Comparison

| Subsystem | Nethermind | Zig Client | Effect-TS Client |
|-----------|:----------:|:----------:|:----------------:|
| DB (persistent storage) | RocksDB | In-memory only | In-memory only |
| Merkle Patricia Trie | Full | 80% | 95% |
| World State + Journal | Full | 85% | 90% |
| EVM Execution | Full | 80% (via Guillotine) | 70% (placeholder) |
| Block Processing | Full | 85% | 90% |
| Consensus (PoW/PoS) | Full (4 engines) | Not started | Not started |
| TxPool | Full | 75% | 85% |
| JSON-RPC | Full (60+ methods) | 75% (4 methods + batch) | 75% (framework only) |
| Engine API | Full | 55% (types complete) | 30% |
| Networking (devp2p) | Full | 55% | 20% |
| Sync (full/fast/snap) | Full | 70% | 50% |
| CLI + Config | Full | 90% | 20% |
| Monitoring/Metrics | Full | Not started | Not started |
| L2 Support | Optimism, Taiko | Not started | Not started |

### Key Gaps vs Nethermind

Both clients are missing:
- **Consensus engine** — No PoW/PoA/PoS implementation (Nethermind has 4 consensus engines)
- **Persistent storage** — RocksDB backends are stubbed in both
- **Full networking** — Peer discovery, connection management, and wire protocol are incomplete
- **Engine API handlers** — Type system is complete in Zig but all payload/forkchoice handlers are stubbed
- **End-to-end wiring** — No subsystem can execute a full block or sync from the network yet
- **Monitoring** — No metrics, health checks, or structured logging
- **Testing and polish** — Neither client has started integration testing against ethereum-tests, execution-spec-tests, or hive. Unit test coverage exists for both clients (500+ tests in Zig, 65 test files in Effect-TS)

### Where XVI Leads

- **EVM engine** — Guillotine passes 100% of ethereum/tests (Frontier through Prague), which many production clients still work toward
- **Architecture** — Both clients mirror Nethermind's module boundaries, making the remaining work well-scoped
- **Primitives** — Voltaire provides production-quality types (Address, Block, Transaction, RLP, Crypto, Precompiles) shared across both clients
- **Type coverage** — Engine API types are complete through V6 (Osaka) with fork-aware capability negotiation

### Current Priorities

1. **Engine API handler implementation** — The type system is complete; implementing `newPayload`, `forkchoiceUpdated`, and `getPayload` would unlock CL integration
2. **Block execution wiring** — Connect EVM processor -> state -> blockchain for end-to-end block execution
3. **RocksDB backend** — Move from in-memory to persistent storage
4. **Peer discovery** — Implement discv4/v5 for network participation
5. **eth/68 protocol** — Wire block/tx propagation over RLPx
