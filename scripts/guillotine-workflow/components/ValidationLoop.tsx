import { Sequence } from "smithers-orchestrator";
import { tables } from "../smithers";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import { Implement } from "./Implement";
import { Test } from "./Test";
import { Benchmark } from "./Benchmark";
import { SpecReview } from "./SpecReview";
import { CodeReview } from "./CodeReview";
import { ReviewFix } from "./ReviewFix";

type ValidationLoopProps = {
  target: Target;
  ticket: Ticket;
  planFilePath: string;
  contextFilePath: string;
  implementationSteps: string[] | null;
  ctx: any;
};

export function ValidationLoop({
  target,
  ticket,
  planFilePath,
  contextFilePath,
  implementationSteps,
  ctx,
}: ValidationLoopProps) {
  // Read latest outputs from previous iterations (populated by the outer Ralph re-render)
  const latestImplement = ctx.outputMaybe(tables.implement, { nodeId: `${ticket.id}:implement` }) as any;
  const latestTest = ctx.outputMaybe(tables.test_results, { nodeId: `${ticket.id}:test` }) as any;
  const latestSpecReview = ctx.outputMaybe(tables.spec_review, { nodeId: `${ticket.id}:spec-review` }) as any;
  const latestCodeReview = ctx.outputMaybe(tables.code_review, { nodeId: `${ticket.id}:code-review` }) as any;

  // Collect review feedback for the implement step
  const specApproved = latestSpecReview?.severity === "none";
  const codeApproved = latestCodeReview?.severity === "none";

  const reviewFeedback = (() => {
    const parts: string[] = [];
    if (latestSpecReview && !specApproved) {
      parts.push(`SPEC REVIEW (${latestSpecReview.severity}): ${latestSpecReview.feedback}`);
      if (latestSpecReview.issues) {
        parts.push(`Issues: ${latestSpecReview.issues.join("; ")}`);
      }
    }
    if (latestCodeReview && !codeApproved) {
      parts.push(`CODE REVIEW (${latestCodeReview.severity}): ${latestCodeReview.feedback}`);
      if (latestCodeReview.issues) {
        parts.push(`Issues: ${latestCodeReview.issues.join("; ")}`);
      }
    }
    return parts.length > 0 ? parts.join("\n\n") : null;
  })();

  const noReviewIssues = specApproved && codeApproved;

  return (
    <Sequence>
      <Implement
        target={target}
        ticket={ticket}
        planFilePath={planFilePath}
        contextFilePath={contextFilePath}
        implementationSteps={implementationSteps}
        previousImplementation={latestImplement ?? null}
        reviewFeedback={reviewFeedback}
        failingTests={latestTest?.failingSummary ?? null}
      />

      <Test target={target} ticket={ticket} />

      <Benchmark
        target={target}
        ticket={ticket}
        filesCreated={latestImplement?.filesCreated ?? null}
        filesModified={latestImplement?.filesModified ?? null}
        whatWasDone={latestImplement?.whatWasDone ?? null}
      />

      <SpecReview
        target={target}
        ticket={ticket}
        filesCreated={latestImplement?.filesCreated ?? null}
        filesModified={latestImplement?.filesModified ?? null}
        unitTests={latestTest?.unitTestsPassed ? "PASS" : "FAIL"}
        specTests={latestTest?.specTestsPassed ? "PASS" : "FAIL"}
        integrationTests={latestTest?.integrationTestsPassed ? "PASS" : "FAIL"}
        nethermindDiff={latestTest?.nethermindDiffPassed ? "PASS" : "FAIL"}
        failingSummary={latestTest?.failingSummary ?? null}
      />

      <CodeReview
        target={target}
        ticket={ticket}
        filesCreated={latestImplement?.filesCreated ?? null}
        filesModified={latestImplement?.filesModified ?? null}
      />

      <ReviewFix
        target={target}
        ticket={ticket}
        specSeverity={latestSpecReview?.severity ?? "none"}
        specFeedback={latestSpecReview?.feedback ?? ""}
        specIssues={latestSpecReview?.issues ?? null}
        codeSeverity={latestCodeReview?.severity ?? "none"}
        codeFeedback={latestCodeReview?.feedback ?? ""}
        codeIssues={latestCodeReview?.issues ?? null}
        skipIf={noReviewIssues}
      />
    </Sequence>
  );
}
