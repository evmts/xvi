import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import ResearchPrompt from "../steps/research.mdx";

type ResearchProps = {
  target: Target;
  ticket: Ticket;
};

export function Research({ target, ticket }: ResearchProps) {
  const agent = makeClaude(target);

  return (
    <Task id={`${ticket.id}:research`} output={tables.research} agent={agent} retries={2}>
      <ResearchPrompt
        ticketId={ticket.id}
        ticketTitle={ticket.title}
        ticketDescription={ticket.description}
        ticketCategory={ticket.category}
        referenceFiles={ticket.referenceFiles}
        relevantFiles={ticket.relevantFiles}
      />
    </Task>
  );
}
