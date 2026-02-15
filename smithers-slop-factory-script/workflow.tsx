import { Sequence, Ralph } from "smithers-orchestrator";
import { Workflow, smithers, tables } from "./smithers";
import { getTarget } from "./targets";
import { categories } from "./categories";
import type { Ticket } from "./db/schemas";
import { CodebaseReview } from "./components/CodebaseReview";
import { Discover } from "./components/Discover";
import { TicketPipeline } from "./components/TicketPipeline";
import { UpdateProgress } from "./components/UpdateProgress";
import { IntegrationTest } from "./components/IntegrationTest";

export default smithers((ctx) => {
  const targetId =
    (ctx as any).input?.target ?? process.env.WORKFLOW_TARGET ?? "zig";
  const target = getTarget(targetId);

  // --- Collect review tickets from CodebaseReview (one per category) ---
  const reviewTickets: Ticket[] = [];
  const reviewSummaryParts: string[] = [];

  for (const { id } of categories) {
    const review = ctx.outputMaybe(tables.category_review, {
      nodeId: `codebase-review:${id}`,
    }) as any;
    if (review?.suggestedTickets) {
      reviewTickets.push(...review.suggestedTickets);
    }
    if (review && review.overallSeverity !== "none") {
      reviewSummaryParts.push(
        `${id} (${review.overallSeverity}): ${review.specCompliance.feedback}`,
      );
    }
  }
  const reviewFindings =
    reviewSummaryParts.length > 0 ? reviewSummaryParts.join("\n") : null;

  // --- Collect feature tickets from Discover ---
  const discoverOutput = ctx.outputMaybe(tables.discover, {
    nodeId: "discover",
  }) as any;
  const featureTickets: Ticket[] = discoverOutput?.tickets ?? [];

  // --- Sort helpers ---
  const priorityOrder: Record<string, number> = {
    critical: 0,
    high: 1,
    medium: 2,
    low: 3,
  };
  const sortByPriority = (a: Ticket, b: Ticket) =>
    (priorityOrder[a.priority] ?? 3) - (priorityOrder[b.priority] ?? 3);

  // --- Find completed tickets (across both review and feature tickets) ---
  const allKnownTickets = [
    ...reviewTickets.sort(sortByPriority),
    ...featureTickets.sort(sortByPriority),
  ];

  const completedTicketIds = allKnownTickets
    .filter((t) => {
      const report = ctx.outputMaybe(tables.report, {
        nodeId: `${t.id}:report`,
      }) as any;
      return report?.status === "complete";
    })
    .map((t) => t.id);

  // --- Unfinished tickets: review first, then feature ---
  const unfinishedTickets = allKnownTickets.filter(
    (t) => !completedTicketIds.includes(t.id),
  );

  // --- Progress ---
  const latestProgress = ctx.outputMaybe(tables.progress, {
    nodeId: "update-progress",
  }) as any;
  const previousProgress = latestProgress?.summary ?? null;

  return (
    <Workflow name={`guillotine-${target.id}`}>
      <Ralph until={false} maxIterations={Infinity} onMaxReached="return-last">
        <Sequence>
          {/* Before starting review vs reference implementation to see what progress is */}
          <UpdateProgress
            target={target}
            completedTickets={completedTicketIds}
          />
          {/* Do high level codebase reviews to generate tickets to improve past code */}
          <CodebaseReview target={target} />
          {/* Identify new code/features that should be done */}
          <Discover
            target={target}
            completedTicketIds={completedTicketIds}
            previousProgress={previousProgress}
            reviewFindings={reviewFindings}
          />

          {/* Execute all tickets: review tickets first (from CodebaseReview), then feature tickets (from Discover) */}
          {/* The pipeline is a research, plan, implement, review loop until reviewers say LGTM */}
          {unfinishedTickets.map((ticket) => (
            <TicketPipeline
              key={ticket.id}
              target={target}
              ticket={ticket}
              ctx={ctx}
            />
          ))}
          {/* After all ticket pipelines, try to set up/run external test suites */}
          {/* When blocked we will flag that so triage agents prioritize unblocking */}
          <IntegrationTest target={target} />
        </Sequence>
      </Ralph>
    </Workflow>
  );
});
