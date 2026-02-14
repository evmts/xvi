import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import ReviewFixPrompt from "../steps/review-fix.mdx";

type ReviewFixProps = {
  target: Target;
  ticket: Ticket;
  specSeverity: string;
  specFeedback: string;
  specIssues: string[] | null;
  codeSeverity: string;
  codeFeedback: string;
  codeIssues: string[] | null;
  skipIf?: boolean;
};

export function ReviewFix({
  target,
  ticket,
  specSeverity,
  specFeedback,
  specIssues,
  codeSeverity,
  codeFeedback,
  codeIssues,
  skipIf,
}: ReviewFixProps) {
  const agent = makeClaude(target);

  return (
    <Task id={`${ticket.id}:review-fix`} output={tables.review_fix} agent={agent} retries={2} skipIf={skipIf}>
      <ReviewFixPrompt
        ticketId={ticket.id}
        ticketTitle={ticket.title}
        ticketCategory={ticket.category}
        specSeverity={specSeverity}
        specFeedback={specFeedback}
        specIssues={specIssues}
        codeSeverity={codeSeverity}
        codeFeedback={codeFeedback}
        codeIssues={codeIssues}
      />
    </Task>
  );
}
