import { Sequence } from "smithers-orchestrator";
import { Task, tables } from "../smithers";
import { categories } from "../categories";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import IntegrationTestPrompt from "../steps/integration-test.mdx";

const categoryTestSuites: Record<string, {
  suites: string[];
  setupHints: string[];
  fixtures: string[];
}> = {
  "phase-0-db": {
    suites: [],
    setupHints: ["No external test suite — just zig build test"],
    fixtures: [],
  },
  "phase-1-trie": {
    suites: ["ethereum-tests/TrieTests"],
    setupHints: [
      "Load ethereum-tests/TrieTests/trietest.json and trieanyorder.json",
      "Each fixture has input key-value pairs and expected root hash",
      "Run: zig build specs (already covers TrieTests if harness exists)",
    ],
    fixtures: ["ethereum-tests/TrieTests/trietest.json", "ethereum-tests/TrieTests/trieanyorder.json"],
  },
  "phase-2-world-state": {
    suites: ["ethereum-tests/GeneralStateTests (subset)"],
    setupHints: [
      "GeneralStateTests test full state transitions — need EVM + world state wired together",
      "Start with simplest tests: stExample/, stCallCreateCallCodeTest/",
    ],
    fixtures: ["ethereum-tests/GeneralStateTests/"],
  },
  "phase-3-evm-state": {
    suites: ["ethereum-tests/GeneralStateTests", "execution-spec-tests consume"],
    setupHints: [
      "zig build specs already runs GeneralStateTests",
      "execution-spec-tests needs t8n tool: check if we can build one",
      "cd execution-spec-tests && uv sync --all-extras",
      "uv run consume direct --bin=<path-to-our-t8n> fixtures/",
    ],
    fixtures: ["ethereum-tests/GeneralStateTests/", "execution-spec-tests/fixtures/"],
  },
  "phase-4-blockchain": {
    suites: ["ethereum-tests/BlockchainTests", "execution-spec-tests blockchain fixtures"],
    setupHints: [
      "BlockchainTests validate full block processing (header, txs, state root)",
      "Need blockchain module to process blocks end-to-end",
      "Start with ethereum-tests/BlockchainTests/ValidBlocks/",
    ],
    fixtures: ["ethereum-tests/BlockchainTests/", "execution-spec-tests/fixtures/blockchain_tests/"],
  },
  "phase-5-txpool": {
    suites: ["ethereum-tests/TransactionTests"],
    setupHints: [
      "TransactionTests validate tx parsing and signature verification",
      "14 categories: ttAddress, ttData, ttEIP1559, ttEIP2930, ttGasLimit, etc.",
      "Each fixture has rlp-encoded tx + expected validity per hardfork",
    ],
    fixtures: ["ethereum-tests/TransactionTests/"],
  },
  "phase-6-jsonrpc": {
    suites: ["execution-apis OpenRPC validation", "hive rpc-compat (long-term)"],
    setupHints: [
      "execution-apis/src/eth/ has OpenRPC spec for all JSON-RPC methods",
      "Can validate response schemas against spec without running hive",
      "hive rpc-compat needs: Docker, Go 1.24, client adapter in hive/clients/",
    ],
    fixtures: ["execution-apis/src/eth/"],
  },
  "phase-7-engine-api": {
    suites: ["execution-apis Engine spec", "hive engine simulator (long-term)"],
    setupHints: [
      "execution-apis/src/engine/ has Engine API spec",
      "execution-spec-tests/fixtures/blockchain_tests_engine/ has engine test fixtures",
      "hive engine simulator needs full client running",
    ],
    fixtures: ["execution-apis/src/engine/", "execution-spec-tests/fixtures/blockchain_tests_engine/"],
  },
  "phase-8-networking": {
    suites: ["devp2p wire test vectors", "hive devp2p simulator (long-term)"],
    setupHints: [
      "devp2p/discv5-wire-test-vectors.md has hex-encoded test vectors for discovery v5",
      "Parse the markdown test vectors into a Zig test file",
      "hive devp2p simulator needs networking module running",
    ],
    fixtures: ["devp2p/discv5-wire-test-vectors.md"],
  },
  "phase-9-sync": {
    suites: ["hive sync simulator (long-term)"],
    setupHints: [
      "Sync testing requires full networking + blockchain modules",
      "hive sync simulator tests block/state sync protocols",
      "Likely blocked until phase 4 + 8 are done",
    ],
    fixtures: [],
  },
  "phase-10-runner": {
    suites: ["hive full node tests (long-term)"],
    setupHints: [
      "Full node testing requires all modules integrated",
      "Start with: can the binary start and respond to a health check?",
      "hive tests need Docker adapter",
    ],
    fixtures: [],
  },
};

type IntegrationTestProps = {
  target: Target;
};

export function IntegrationTest({ target }: IntegrationTestProps) {
  const agent = makeClaude(target);

  return (
    <Sequence>
      {categories.map(({ id, name }) => {
        const suiteInfo = categoryTestSuites[id] ?? { suites: [], setupHints: [], fixtures: [] };
        return (
          <Task
            key={id}
            id={`integration-test:${id}`}
            output={tables.integration_test}
            agent={agent}
            retries={2}
          >
            <IntegrationTestPrompt
              categoryId={id}
              categoryName={name}
              suites={suiteInfo.suites}
              setupHints={suiteInfo.setupHints}
              fixtures={suiteInfo.fixtures}
            />
          </Task>
        );
      })}
    </Sequence>
  );
}
