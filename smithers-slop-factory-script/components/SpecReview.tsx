import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import SpecReviewPrompt from "../steps/spec-review.mdx";

type SpecReviewProps = {
  target: Target;
  ticket: Ticket;
  filesCreated: string[] | null;
  filesModified: string[] | null;
  unitTests: string;
  specTests: string;
  integrationTests: string;
  nethermindDiff: string;
  failingSummary: string | null;
};

export function SpecReview({
  target,
  ticket,
  filesCreated,
  filesModified,
  unitTests,
  specTests,
  integrationTests,
  nethermindDiff,
  failingSummary,
}: SpecReviewProps) {
  const agent = makeClaude(target);

  return (
    <Task id={`${ticket.id}:spec-review`} output={tables.spec_review} agent={agent} retries={2}>
      <SpecReviewPrompt
        ticketId={ticket.id}
        ticketTitle={ticket.title}
        ticketCategory={ticket.category}
        filesCreated={filesCreated}
        filesModified={filesModified}
        unitTests={unitTests}
        specTests={specTests}
        integrationTests={integrationTests}
        nethermindDiff={nethermindDiff}
        failingSummary={failingSummary}
      />
    </Task>
  );
}
