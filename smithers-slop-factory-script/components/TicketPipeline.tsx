import { Sequence } from "smithers-orchestrator";
import { tables } from "../smithers";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import { Research } from "./Research";
import { Plan } from "./Plan";
import { ValidationLoop } from "./ValidationLoop";
import { Report } from "./Report";

type TicketPipelineProps = {
  target: Target;
  ticket: Ticket;
  ctx: any;
};

export function TicketPipeline({ target, ticket, ctx }: TicketPipelineProps) {
  // Check if ticket is already complete
  const report = ctx.outputMaybe(tables.report, { nodeId: `${ticket.id}:report` }) as any;
  const ticketComplete = report?.status === "complete";

  // Read pipeline step outputs
  const research = ctx.outputMaybe(tables.research, { nodeId: `${ticket.id}:research` }) as any;
  const plan = ctx.outputMaybe(tables.plan, { nodeId: `${ticket.id}:plan` }) as any;
  const specReview = ctx.outputMaybe(tables.spec_review, { nodeId: `${ticket.id}:spec-review` }) as any;
  const codeReview = ctx.outputMaybe(tables.code_review, { nodeId: `${ticket.id}:code-review` }) as any;
  const reviewFix = ctx.outputMaybe(tables.review_fix, { nodeId: `${ticket.id}:review-fix` }) as any;
  const test = ctx.outputMaybe(tables.test_results, { nodeId: `${ticket.id}:test` }) as any;

  // Count how many review rounds have happened
  const reviewRounds = specReview ? 1 : 0; // TODO: track actual iteration count

  return (
    <Sequence skipIf={ticketComplete}>
      <Research target={target} ticket={ticket} />

      <Plan
        target={target}
        ticket={ticket}
        contextFilePath={research?.contextFilePath ?? `docs/context/${ticket.id}.md`}
        researchSummary={research?.summary ?? null}
      />

      <ValidationLoop
        target={target}
        ticket={ticket}
        planFilePath={plan?.planFilePath ?? `docs/plans/${ticket.id}.md`}
        contextFilePath={research?.contextFilePath ?? `docs/context/${ticket.id}.md`}
        implementationSteps={plan?.implementationSteps ?? null}
        ctx={ctx}
      />

      <Report
        target={target}
        ticket={ticket}
        specSeverity={specReview?.severity ?? "none"}
        codeSeverity={codeReview?.severity ?? "none"}
        allIssuesResolved={reviewFix?.allIssuesResolved ?? true}
        reviewRounds={reviewRounds}
        unitTests={test?.unitTestsPassed ? "PASS" : "FAIL"}
        specTests={test?.specTestsPassed ? "PASS" : "FAIL"}
        integrationTests={test?.integrationTestsPassed ? "PASS" : "FAIL"}
        nethermindDiff={test?.nethermindDiffPassed ? "PASS" : "FAIL"}
      />
    </Sequence>
  );
}
