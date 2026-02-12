<div align="center">
  <h1>
    Louis
    <br/>
    Ethereum Execution Client in Zig + Effect-TS
    <br/>
    <br/>
  </h1>
  <sup>
    <a href="https://github.com/evmts/louis">
       <img src="https://img.shields.io/badge/zig-0.15.1+-orange.svg" alt="zig version" />
    </a>
    <a href="https://github.com/evmts/louis">
       <img src="https://img.shields.io/badge/effect--ts-3.19+-blue.svg" alt="effect-ts" />
    </a>
    <a href="https://github.com/evmts/louis/actions">
      <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="build status" />
    </a>
  </sup>
</div>

Louis is an Ethereum execution client built with [Zig](https://ziglang.org/) and [Effect-TS](https://effect.website/). It uses [guillotine-mini](https://github.com/evmts/guillotine-mini) as its EVM engine and [Voltaire](https://github.com/evmts/voltaire) for Ethereum primitives.

## Architecture

| Component | Language | Description |
|-----------|----------|-------------|
| [guillotine-mini](https://github.com/evmts/guillotine-mini) | Zig | EVM execution engine (opcodes, gas, hardforks Berlin→Prague) |
| [client-ts](./client-ts) | Effect-TS | Execution client modules (blockchain, state, trie, RPC, sync, txpool) |
| [Voltaire](https://github.com/evmts/voltaire) | Zig + TS | Ethereum primitives (Address, Block, Tx, RLP, Crypto, Precompiles) |

## Requirements

- Zig 0.15.1+
- Cargo (for Rust crypto deps)
- Bun or Node.js 20+ (for Effect-TS client)

## Quick Start

**Zig EVM**

```bash
cd guillotine-mini
zig build           # Build EVM
zig build test      # Run unit tests
zig build specs     # Run ethereum/tests
```

**Effect-TS Client**

```bash
cd client-ts
bun install
bun run test        # Run all tests
```

## Client Modules

| Module | Purpose |
|--------|---------|
| `blockchain/` | Block storage, validation, and chain management |
| `state/` | World state, journaled state, transient storage |
| `trie/` | Merkle Patricia Trie implementation |
| `evm/` | EVM host adapter, transaction processing |
| `rpc/` | JSON-RPC server and method handlers |
| `sync/` | Full sync peer request planning |
| `txpool/` | Transaction pool with admission, sorting, and replacement |
| `engine/` | Engine API (consensus-layer interface) |
| `db/` | Database abstraction (RocksDB-compatible) |
| `network/` | RLPx networking |

## Related

- [guillotine-mini](https://github.com/evmts/guillotine-mini) — EVM engine
- [Voltaire](https://github.com/evmts/voltaire) — Ethereum primitives library

## License

See `LICENSE`.
