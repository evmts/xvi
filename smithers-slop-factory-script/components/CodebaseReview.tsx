import { Sequence } from "smithers-orchestrator";
import { Task, tables } from "../smithers";
import { categories } from "../categories";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import CategoryReviewPrompt from "../steps/category-review.mdx";

// Map category IDs to hint directories for the reviewer
const categoryDirs: Record<string, string[]> = {
  "phase-0-db": ["client/db/"],
  "phase-1-trie": ["client/trie/"],
  "phase-2-world-state": ["client/state/"],
  "phase-3-evm-state": ["client/evm/", "src/"],
  "phase-4-blockchain": ["client/blockchain/"],
  "phase-5-txpool": ["client/txpool/"],
  "phase-6-jsonrpc": ["client/rpc/"],
  "phase-7-engine-api": ["client/engine/"],
  "phase-8-networking": ["client/network/"],
  "phase-9-sync": ["client/sync/"],
  "phase-10-runner": ["client/runner/"],
};

type CodebaseReviewProps = {
  target: Target;
};

export function CodebaseReview({ target }: CodebaseReviewProps) {
  const agent = makeClaude(target);

  return (
    <Sequence>
      {categories.map(({ id, name }) => (
        <Task
          key={id}
          id={`codebase-review:${id}`}
          output={tables.category_review}
          agent={agent}
          retries={2}
        >
          <CategoryReviewPrompt
            categoryId={id}
            categoryName={name}
            relevantDirs={categoryDirs[id] ?? null}
          />
        </Task>
      ))}
    </Sequence>
  );
}
