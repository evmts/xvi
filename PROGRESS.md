# XVI Progress Report

**Date:** 2026-02-15
**Timestamp:** 19:07 UTC

This report compares the XVI Zig client (`client/`) and Effect-TS client (`client-ts/`) against [Nethermind](https://github.com/NethermindEth/nethermind), a production Ethereum execution client in C#. Both XVI implementations mirror Nethermind's architecture across 11 subsystems (Phases 0-10). Testing and polish phases have not started for either client.

---

## Recent Work (since last report)

The most recent development cycle focused on hardening Phase 0 (DB Abstraction) of the Zig client with comptime refactoring:

- **Phase 0 — DB Abstraction:** Added `Database.init` comptime helper to eliminate manual vtable boilerplate; applied it to both MemoryDatabase and NullDb backends; removed dead `types.zig` (consolidated into adapter.zig); eliminated `constCast` usage in NullDb by scoping globals inside struct; improved var safety documentation; added Voltaire Zig primitives symlink (10 files, 4,742 LOC, 103 tests)
- **Workflow:** Added IntegrationTest phase to Smithers pipeline; auto-schema output for ticket system; strengthened rules against backup files in docs

---

## Reference: Nethermind Subsystems

Nethermind ships 48+ modules covering: DB (RocksDB), Merkle Patricia Trie, World State, EVM + Precompiles, Blockchain (block processing, validators, canonical chain), Consensus (Ethash/Clique/AuRa/Merge), TxPool, JSON-RPC (HTTP/WS), Engine API (CL bridge), Networking (devp2p, discv4/v5, DNS discovery, RLPx, eth/68, snap/1), Synchronization (full/fast/snap sync), Config/CLI/Logging, Monitoring/HealthChecks, Serialization (RLP/JSON/SSZ), History/Era1 archives, and L2 support (Optimism, Taiko).

---

## Zig Client (`client/`)

**Stats:** ~30,450 lines of source across 75 files (11 subsystems, 14 directories), 760 tests

| Phase | Subsystem | Completeness | What's Done | What's Missing |
|-------|-----------|:------------:|-------------|----------------|
| 0 | DB Abstraction | 92% | Comptime `Database.init` vtable helper, in-memory backend, null backend, read-only overlay, column families, provider registry, adapter layer with consolidated types, 103 tests (10 files, 4,742 LOC) | RocksDB FFI (stubbed at 324 LOC) |
| 1 | Merkle Patricia Trie | 80% | `patricialize()` algorithm matching Python spec, node types (leaf/extension/branch), <32-byte inlining, keccak256 via Voltaire, benchmarks, 28 tests (6 files, 1,618 LOC) | High-level trie helpers partial |
| 2 | World State | 85% | Generic journal with snapshot/restore (740 LOC), account helpers (EIP-161/684/7610 empty predicates), change tracking (create/update/delete/touch), journal ops, 60 tests (7 files, 2,217 LOC) | Integration with full execution loop |
| 3 | EVM Integration | 80% | Intrinsic gas calculator (all TX types incl. EIP-7702), TX validation, EIP-1559 fee calculation, EIP-7623 calldata floor gas (Prague+), `preprice_transaction` batch validation, host adapter skeleton, 53 tests (5 files, 2,217 LOC) | Full state execution wiring, balance/nonce checks, receipt generation |
| 4 | Blockchain | 85% | Chain management via Voltaire Blockchain (3,075 LOC), head/canonical/reorg helpers, typed validator framework (863 LOC), strict canonicality, fork boundary detection, BLOCKHASH spec-total helper, common ancestor (nullable + strict), 151 tests (6 files, 4,357 LOC) | Block insertion/reorg logic, state root computation |
| 5 | TxPool | 75% | Vtable-based pool interface (12 methods), admission checks (size/gas/blob/nonce), EIP-1559 sorter, broadcast policy, blob-specific lookup, hash-cache duplicate filter, handling options, limits, 40 tests (9 files, 2,979 LOC) | Core pool data structure implementation, eviction, replacement |
| 6 | JSON-RPC | 75% | Envelope parsing, EIP-1474 error codes, response serializers, batch executor with size cap, single-request dispatch router, `eth_chainId`, `net_version`, `web3_clientVersion`, `web3_sha3`, shared scanner, 125 tests (10 files, 3,899 LOC) | eth_* state/account query methods (eth_getBalance, eth_call, etc.), HTTP/WS server transport |
| 7 | Engine API | 55% | Full type definitions (V1-V6), vtable interface (20+ handlers), request/response param types, fork-aware capabilities provider (Paris-Osaka), BlobsBundle cardinality constraints, executionRequests validation, 81 tests (3 files, 4,553 LOC) | All handler implementations (newPayload, forkchoiceUpdated, getPayload are type-complete but logic-stubbed) |
| 8 | Networking | 55% | RLPx frame encode/decode, EIP-8 auth/ack handshake decoders, size-prefix decoder, secret derivation (ECDH+KDF), MAC state init, Snappy guards, benchmarks, 51 tests (8 files, 1,399 LOC) | Handshake state machine execution, peer discovery (discv4/v5), eth/68 protocol, peer management, network I/O |
| 9 | Sync | 70% | Manager startup planner with feed activation, sync mode flags, full/snap request structures, StorageRangeRequest, BlocksRequest receipt_hashes, status helpers, validation guards, 53 tests (7 files, 1,814 LOC) | Protocol handlers, actual block/state fetching, feed implementations |
| 10 | Runner/CLI | 90% | CLI argument parsing (chain-id, network-id, hardfork, trace), genesis JSON loading (mainnet/sepolia/zhejiang), config defaults (4 files, 651 LOC) | Main block processing loop, service wiring |

**Shared EVM engine:** [Guillotine](https://github.com/evmts/guillotine) — full hardfork support Frontier through Prague, 20+ EIPs, 100% ethereum/tests passing.

**Overall: ~76% feature-complete.** Infrastructure layers (DB, state, trie, CLI) are solid. The DB layer has been significantly hardened with comptime vtable initialization that eliminates manual pointer casts and dead code. Mid-layers (blockchain, txpool, EVM integration) have matured with comprehensive validation logic and tests. The Engine API type system is complete (all versions V1-V6) though handler logic remains stubbed. Networking has usable RLPx protocol primitives but no peer management. The critical gap is end-to-end wiring: no subsystem can yet execute a full block or sync from the network.

---

## Effect-TS Client (`client-ts/`)

**Stats:** ~32,900 lines of source across 152 files (11 subsystems), 65 test files, 11 benchmarks

| Phase | Subsystem | Completeness | What's Done | What's Missing |
|-------|-----------|:------------:|-------------|----------------|
| 0 | DB Abstraction | 85% | Full Effect.js service (get/put/delete/batch/iterator/snapshot), factory pattern, column families, null/read-only variants (26 files, 4,646 LOC) | RocksDB backend (stubbed) |
| 1 | Merkle Patricia Trie | 95% | Secured/unsecured variants, nibble expansion, node compression, RLP codec, `patricialize()`, NodeLoader, NodeStorage, extensive tests + benchmarks (28 files, 5,350 LOC) | — |
| 2 | World State | 90% | Journaling with snapshot/restore, account model, transaction boundary (rollback/commit), transient storage (EIP-1153), WorldStateReader (19 files, 4,002 LOC) | — |
| 3 | EVM Integration | 70% | TransactionProcessor (pre/post execution), host adapter, intrinsic gas calculator, access list builder, refund calculator, release spec tracking, TransactionEnvironmentBuilder (19 files, 5,324 LOC) | EvmExecutor is placeholder (bridges to Zig EVM, not wired) |
| 4 | Blockchain | 90% | Block tree (canonical + orphans), fork-choice state machine, genesis validation, header validation, BLOCKHASH cache/store, gas accounting, read-only overlay (23 files, 5,275 LOC) | — |
| 5 | TxPool | 85% | Mempool service (add/remove/get/iterate), admission validator (gas/balance/nonce/blob), fee-based sorting (EIP-1559 + blob pricing) (6 files, 2,907 LOC) | Persistence integration, eviction policies |
| 6 | JSON-RPC | 75% | Method dispatcher, request/response parsing, batch support, EIP-1474 + Nethermind error codes, server config (12 files, 1,933 LOC) | Actual eth_*/engine_* method handlers, HTTP server |
| 7 | Engine API | 30% | Capability exchange (`engine_exchangeCapabilities`), client version, Paris method constants (4 files, 721 LOC) | Payload handling, fork-choice updates |
| 8 | Networking | 20% | RLPx capability negotiation, Snappy compression validation (4 files, 992 LOC) | Full p2p peer management, discovery, eth protocol |
| 9 | Sync | 50% | Full sync request planner (batch splitting for headers/bodies/receipts), per-peer rate limiting (4 files, 1,134 LOC) | P2P message transport, actual sync execution |
| 10 | Runner/CLI | 20% | Basic CLI argument parsing (--help, --version, start), RunnerMain/RunnerConfig (4 files, 570 LOC) | Full config system, process lifecycle, service wiring |

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
- **Testing and polish** — Neither client has started integration testing against ethereum-tests, execution-spec-tests, or hive. Unit test coverage: 760 tests in Zig, 65 test files in Effect-TS

### Where XVI Leads

- **EVM engine** — Guillotine passes 100% of ethereum/tests (Frontier through Prague), which many production clients still work toward
- **Architecture** — Both clients mirror Nethermind's module boundaries, making the remaining work well-scoped
- **Primitives** — Voltaire provides production-quality types (Address, Block, Transaction, RLP, Crypto, Precompiles) shared across both clients
- **Type coverage** — Engine API types are complete through V6 (Osaka) with fork-aware capability negotiation
- **Comptime DI** — DB layer now uses comptime vtable initialization (`Database.init`) eliminating manual pointer casts — a pattern to replicate across other subsystems
- **Workflow automation** — Component-based ticket pipeline (Smithers) with IntegrationTest phase automates codebase review, ticket generation, implementation, and testing

### Current Priorities

1. **Engine API handler implementation** — The type system is complete; implementing `newPayload`, `forkchoiceUpdated`, and `getPayload` would unlock CL integration
2. **Block execution wiring** — Connect EVM processor -> state -> blockchain for end-to-end block execution
3. **RocksDB backend** — Move from in-memory to persistent storage
4. **Comptime vtable pattern rollout** — Apply `Database.init`-style comptime helpers to TxPool, Engine API, and other vtable-based subsystems
5. **Peer discovery** — Implement discv4/v5 for network participation
6. **eth/68 protocol** — Wire block/tx propagation over RLPx
