import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import CodeReviewPrompt from "../steps/code-review.mdx";

type CodeReviewProps = {
  target: Target;
  ticket: Ticket;
  filesCreated: string[] | null;
  filesModified: string[] | null;
};

export function CodeReview({ target, ticket, filesCreated, filesModified }: CodeReviewProps) {
  const agent = makeClaude(target);

  return (
    <Task id={`${ticket.id}:code-review`} output={tables.code_review} agent={agent} retries={2}>
      <CodeReviewPrompt
        ticketId={ticket.id}
        ticketTitle={ticket.title}
        ticketCategory={ticket.category}
        filesCreated={filesCreated}
        filesModified={filesModified}
      />
    </Task>
  );
}
