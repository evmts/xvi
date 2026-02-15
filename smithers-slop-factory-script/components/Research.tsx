import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import ResearchPrompt from "../steps/research.mdx";

// Map category IDs to authoritative submodule paths for research
const categorySubmodules: Record<string, string[]> = {
  "phase-0-db": [
    "nethermind/src/Nethermind/Nethermind.Db/",
  ],
  "phase-1-trie": [
    "execution-specs/src/ethereum/forks/frontier/trie.py",
    "execution-specs/src/ethereum/rlp.py",
    "nethermind/src/Nethermind/Nethermind.Trie/",
    "ethereum-tests/TrieTests/",
    "yellowpaper/ (Appendix D)",
  ],
  "phase-2-world-state": [
    "execution-specs/src/ethereum/forks/*/state.py",
    "nethermind/src/Nethermind/Nethermind.State/",
    "ethereum-tests/GeneralStateTests/",
  ],
  "phase-3-evm-state": [
    "execution-specs/src/ethereum/forks/*/vm/__init__.py",
    "execution-specs/src/ethereum/forks/*/fork.py",
    "nethermind/src/Nethermind/Nethermind.Evm/",
    "guillotine-mini/src/",
    "ethereum-tests/GeneralStateTests/",
    "execution-spec-tests/fixtures/state_tests/",
  ],
  "phase-4-blockchain": [
    "execution-specs/src/ethereum/forks/*/fork.py",
    "nethermind/src/Nethermind/Nethermind.Blockchain/",
    "ethereum-tests/BlockchainTests/",
    "execution-spec-tests/fixtures/blockchain_tests/",
    "consensus-specs/ (block validation)",
  ],
  "phase-5-txpool": [
    "EIPs/EIPS/eip-1559.md",
    "EIPs/EIPS/eip-2930.md",
    "EIPs/EIPS/eip-4844.md",
    "nethermind/src/Nethermind/Nethermind.TxPool/",
  ],
  "phase-6-jsonrpc": [
    "execution-apis/src/eth/",
    "nethermind/src/Nethermind/Nethermind.JsonRpc/",
    "hive/ (RPC test suites)",
    "execution-spec-tests/ (RPC fixtures)",
  ],
  "phase-7-engine-api": [
    "execution-apis/src/engine/",
    "EIPs/EIPS/eip-3675.md",
    "EIPs/EIPS/eip-4399.md",
    "nethermind/src/Nethermind/Nethermind.Merge.Plugin/",
    "hive/ (Engine API tests)",
    "execution-spec-tests/fixtures/blockchain_tests_engine/",
  ],
  "phase-8-networking": [
    "devp2p/rlpx.md",
    "devp2p/caps/eth.md",
    "devp2p/caps/snap.md",
    "devp2p/discv4.md",
    "devp2p/discv5/discv5.md",
    "devp2p/enr.md",
    "nethermind/src/Nethermind/Nethermind.Network/",
    "hive/ (devp2p tests)",
  ],
  "phase-9-sync": [
    "devp2p/caps/eth.md",
    "devp2p/caps/snap.md",
    "nethermind/src/Nethermind/Nethermind.Synchronization/",
    "hive/ (sync tests)",
  ],
  "phase-10-runner": [
    "nethermind/src/Nethermind/Nethermind.Runner/",
    "hive/ (full node tests)",
  ],
};

type ResearchProps = {
  target: Target;
  ticket: Ticket;
};

export function Research({ target, ticket }: ResearchProps) {
  const agent = makeClaude(target);
  const submodulePaths = categorySubmodules[ticket.category] ?? [];

  return (
    <Task id={`${ticket.id}:research`} output={tables.research} agent={agent} retries={2}>
      <ResearchPrompt
        ticketId={ticket.id}
        ticketTitle={ticket.title}
        ticketDescription={ticket.description}
        ticketCategory={ticket.category}
        referenceFiles={ticket.referenceFiles}
        relevantFiles={ticket.relevantFiles}
        submodulePaths={submodulePaths}
      />
    </Task>
  );
}
