import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import PlanPrompt from "../steps/plan.mdx";

type PlanProps = {
  target: Target;
  ticket: Ticket;
  contextFilePath: string;
  researchSummary: string | null;
};

export function Plan({ target, ticket, contextFilePath, researchSummary }: PlanProps) {
  const agent = makeClaude(target);

  return (
    <Task id={`${ticket.id}:plan`} output={tables.plan} agent={agent} retries={2}>
      <PlanPrompt
        ticketId={ticket.id}
        ticketTitle={ticket.title}
        ticketDescription={ticket.description}
        ticketCategory={ticket.category}
        acceptanceCriteria={ticket.acceptanceCriteria}
        contextFilePath={contextFilePath}
        researchSummary={researchSummary}
      />
    </Task>
  );
}
