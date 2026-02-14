import { Sequence, Ralph } from "smithers-orchestrator";
import { Workflow, smithers, tables } from "./smithers";
import { getTarget } from "./targets";
import { categories } from "./categories";
import type { Ticket } from "./db/schemas";
import { CodebaseReview } from "./components/CodebaseReview";
import { Discover } from "./components/Discover";
import { TicketPipeline } from "./components/TicketPipeline";
import { UpdateProgress } from "./components/UpdateProgress";

export default smithers((ctx) => {
  const targetId = (ctx as any).input?.target ?? process.env.WORKFLOW_TARGET ?? "zig";
  const target = getTarget(targetId);

  // --- Collect review tickets from CodebaseReview (one per category) ---
  const reviewTickets: Ticket[] = [];
  const reviewSummaryParts: string[] = [];

  for (const { id } of categories) {
    const review = ctx.outputMaybe(tables.category_review, { nodeId: `codebase-review:${id}` }) as any;
    if (review?.suggestedTickets) {
      reviewTickets.push(...review.suggestedTickets);
    }
    if (review && review.overallSeverity !== "none") {
      reviewSummaryParts.push(`${id} (${review.overallSeverity}): ${review.specCompliance.feedback}`);
    }
  }
  const reviewFindings = reviewSummaryParts.length > 0 ? reviewSummaryParts.join("\n") : null;

  // --- Collect feature tickets from Discover ---
  const discoverOutput = ctx.outputMaybe(tables.discover, { nodeId: "discover" }) as any;
  const featureTickets: Ticket[] = discoverOutput?.tickets ?? [];

  // --- Merge and order: review tickets first, then feature tickets ---
  const priorityOrder: Record<string, number> = { critical: 0, high: 1, medium: 2, low: 3 };
  const sortByPriority = (a: Ticket, b: Ticket) =>
    (priorityOrder[a.priority] ?? 3) - (priorityOrder[b.priority] ?? 3);

  const allTickets = [
    ...reviewTickets.sort(sortByPriority),
    ...featureTickets.sort(sortByPriority),
  ];

  // --- Find completed tickets ---
  const completedTicketIds = allTickets
    .filter((t) => {
      const report = ctx.outputMaybe(tables.report, { nodeId: `${t.id}:report` }) as any;
      return report?.status === "complete";
    })
    .map((t) => t.id);

  const unfinishedTickets = allTickets.filter(
    (t) => !completedTicketIds.includes(t.id)
  );

  // --- Progress ---
  const latestProgress = ctx.outputMaybe(tables.progress, { nodeId: "update-progress" }) as any;
  const previousProgress = latestProgress?.summary ?? null;

  // Need discovery when there are no tickets at all, or when all current tickets are done
  const allTicketsDone = allTickets.length > 0 && unfinishedTickets.length === 0;
  const noTicketsYet = allTickets.length === 0;
  const needsDiscovery = noTicketsYet || allTicketsDone;

  return (
    <Workflow name={`guillotine-${target.id}`}>
      <Ralph until={false} maxIterations={Infinity} onMaxReached="return-last">
        <Sequence>
          {/* Discovery sequence: UpdateProgress → CodebaseReview → Discover */}
          {needsDiscovery && (
            <Sequence>
              <UpdateProgress target={target} completedTickets={completedTicketIds} />
              <CodebaseReview target={target} />
              <Discover
                target={target}
                completedTicketIds={completedTicketIds}
                previousProgress={previousProgress}
                reviewFindings={reviewFindings}
              />
            </Sequence>
          )}

          {/* Execute tickets sequentially: review tickets first, then feature tickets */}
          {unfinishedTickets.map((ticket) => (
            <TicketPipeline
              key={ticket.id}
              target={target}
              ticket={ticket}
              ctx={ctx}
            />
          ))}
        </Sequence>
      </Ralph>
    </Workflow>
  );
});
