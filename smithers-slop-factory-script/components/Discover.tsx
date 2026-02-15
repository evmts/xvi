import { Task, tables } from "../smithers";
import { categories } from "../categories";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import DiscoverPrompt from "../steps/discover.mdx";

type DiscoverProps = {
  target: Target;
  completedTicketIds: string[];
  previousProgress: string | null;
  reviewFindings: string | null;
};

export function Discover({ target, completedTicketIds, previousProgress, reviewFindings }: DiscoverProps) {
  const agent = makeClaude(target);

  return (
    <Task id="discover" output={tables.discover} agent={agent} retries={2}>
      <DiscoverPrompt
        categories={categories}
        completedTicketIds={completedTicketIds}
        previousProgress={previousProgress}
        reviewFindings={reviewFindings}
      />
    </Task>
  );
}
