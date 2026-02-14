import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import ReportPrompt from "../steps/report-ticket.mdx";

type ReportProps = {
  target: Target;
  ticket: Ticket;
  specSeverity: string;
  codeSeverity: string;
  allIssuesResolved: boolean;
  reviewRounds: number;
  unitTests: string;
  specTests: string;
  integrationTests: string;
  nethermindDiff: string;
};

export function Report({
  target,
  ticket,
  specSeverity,
  codeSeverity,
  allIssuesResolved,
  reviewRounds,
  unitTests,
  specTests,
  integrationTests,
  nethermindDiff,
}: ReportProps) {
  const agent = makeClaude(target);

  return (
    <Task id={`${ticket.id}:report`} output={tables.report} agent={agent} retries={2}>
      <ReportPrompt
        ticketId={ticket.id}
        ticketTitle={ticket.title}
        ticketCategory={ticket.category}
        acceptanceCriteria={ticket.acceptanceCriteria}
        specSeverity={specSeverity}
        codeSeverity={codeSeverity}
        allIssuesResolved={allIssuesResolved}
        reviewRounds={reviewRounds}
        unitTests={unitTests}
        specTests={specTests}
        integrationTests={integrationTests}
        nethermindDiff={nethermindDiff}
      />
    </Task>
  );
}
