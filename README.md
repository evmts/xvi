<div align="center">
  <h1>
    XVI
    <br/>
    An experiment in fully vibecoding an Ethereum execution client
    <br/>
    <br/>
  </h1>
  <sup>
    <a href="https://github.com/evmts/xvi">
       <img src="https://img.shields.io/badge/zig-0.15.1+-orange.svg" alt="zig version" />
    </a>
    <a href="https://github.com/evmts/xvi">
       <img src="https://img.shields.io/badge/effect--ts-3.19+-blue.svg" alt="effect-ts" />
    </a>
    <a href="https://github.com/evmts/xvi">
       <img src="https://img.shields.io/badge/vibecoded-100%25-ff69b4.svg" alt="vibecoded" />
    </a>
  </sup>
</div>

## What is this?

XVI is an experiment to see how far you can get **vibecoding an entire Ethereum execution client** — meaning every line of source code is written by AI agents, orchestrated by [Smithers](https://github.com/evmts/smithers).

The human role is purely architectural: defining what modules to build, what specs to follow, and what tests to pass. The AI does all the implementation. Even this README was vibecoded.

### Current status

- **~19k lines** of Effect-TS source across 87 modules (blockchain, state, trie, EVM host, RPC, sync, txpool, engine, db, networking)
- **~14k lines** of tests (528 tests, 507 passing)
- **EVM engine** provided by [xvi-evm](https://github.com/evmts/xvi) (Zig, also vibecoded) — full hardfork support Frontier → Prague, 20+ EIPs, 100% ethereum/tests passing
- **Primitives** provided by [Voltaire](https://github.com/evmts/voltaire) — Address, Block, Transaction, RLP, Crypto, Precompiles

## Architecture

| Component | Language | Description |
|-----------|----------|-------------|
| [xvi-evm](./xvi-evm) | Zig | EVM execution engine (submodule) |
| [client-ts](./client-ts) | Effect-TS | Execution client modules |
| [smithers](./smithers) | TSX/React | AI workflow orchestrator that generates the code |
| [Voltaire](https://github.com/evmts/voltaire) | Zig + TS | Ethereum primitives (fetched from npm/GitHub releases) |

## How Smithers works

[Smithers](https://github.com/evmts/smithers) is a declarative AI workflow orchestrator that uses **React JSX** to define multi-agent pipelines. It's how all the client code gets generated.

### The core idea

You define AI workflows as React component trees. Each `<Task>` is a node that runs an AI agent. `<Sequence>`, `<Parallel>`, `<Branch>`, and `<Ralph>` (loop) control execution order. The tree **re-renders** after each task completes — just like React re-renders after state changes.

```tsx
/** @jsxImportSource smithers */
import { smithers, Workflow, Task, Sequence } from "smithers";
import { Experimental_Agent as Agent, Output } from "ai";
import { anthropic } from "@ai-sdk/anthropic";

const planAgent = new Agent({
  model: anthropic("claude-sonnet-4-20250514"),
  output: Output.object({ schema: planSchema }),
  instructions: "You are a planning assistant.",
});

export default smithers(db, (ctx) => (
  <Workflow name="build-module">
    <Sequence>
      <Task id="plan" output={schema.plan} agent={planAgent}>
        {`Create a plan for: ${ctx.input.goal}`}
      </Task>
      <Task id="implement" output={schema.code} agent={coderAgent}>
        {`Implement this plan: ${ctx.output(schema.plan, { nodeId: "plan" }).steps}`}
      </Task>
    </Sequence>
  </Workflow>
));
```

### Key features

- **JSX DAG** — Workflows are React component trees. `<Sequence>` runs children in order, `<Parallel>` runs concurrently, `<Ralph>` loops until a condition is met
- **Structured output** — Every task output is validated against a Zod schema. If the agent returns malformed JSON, Smithers auto-retries with the validation error appended
- **SQLite persistence** — All task results are stored in SQLite keyed by `(runId, nodeId, iteration)`. Crash at any point and resume exactly where you left off
- **Reactive re-rendering** — After each task completes, the entire tree re-renders with updated context. Downstream tasks can read upstream outputs via `ctx.output()`
- **Built-in tools** — `read`, `edit`, `bash`, `grep`, `write` — all sandboxed to the workflow root

### Running a workflow

```bash
# CLI
bunx smithers run workflow.tsx --input '{"goal": "Build a trie module"}'

# Resume a crashed run
bunx smithers resume workflow.tsx --run-id abc123
```

### How it generates client code

The typical flow for building a new module:

1. **Plan phase** — An architect agent reads the Ethereum specs and Nethermind reference implementation, produces a structured plan (interfaces, types, key algorithms)
2. **Implement phase** — A coder agent writes the Effect-TS module following the plan, using `read`/`edit`/`bash` tools to create files and run type checks
3. **Test phase** — A test agent writes comprehensive tests using `@effect/vitest`
4. **Review loop** (`<Ralph>`) — A reviewer agent checks the implementation against specs. If issues are found, it loops back with feedback until the reviewer approves or max iterations hit

All intermediate outputs (plans, code, test results, review feedback) are persisted in SQLite, so the process is fully resumable and auditable.

## Client Modules

| Module | Purpose |
|--------|---------|
| `blockchain/` | Block storage, validation, chain management |
| `state/` | World state, journaled state, transient storage |
| `trie/` | Merkle Patricia Trie |
| `evm/` | EVM host adapter, transaction processing, gas accounting |
| `rpc/` | JSON-RPC server and method handlers |
| `sync/` | Full sync peer request planning |
| `txpool/` | Transaction pool with admission, sorting, replacement |
| `engine/` | Engine API (consensus-layer interface) |
| `db/` | Database abstraction (RocksDB-compatible) |
| `network/` | RLPx networking |
| `runner/` | Client runner and CLI |

## Quick Start

**Zig EVM**

```bash
zig build           # Build EVM
zig build test      # Run unit tests
zig build specs     # Run ethereum/tests
```

**Effect-TS Client**

```bash
cd client-ts
bun install
npx vitest run      # Run all tests
```

## Requirements

- Zig 0.15.1+ (EVM)
- Cargo (Rust crypto deps)
- Bun or Node.js 20+ (Effect-TS client)
- Anthropic API key (for running Smithers workflows)

## Related

- [XVI](https://github.com/evmts/xvi) — EVM engine
- [Voltaire](https://github.com/evmts/voltaire) — Ethereum primitives
- [Smithers](https://github.com/evmts/smithers) — AI workflow orchestrator

## License

See `LICENSE`.
