import { Sequence, Ralph } from "smithers-orchestrator";
import { existsSync, readdirSync, statSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Workflow, Task, smithers, tables } from "./smithers";
import { makeCodex } from "./agents/codex";
import { phases } from "./phases";
import { getTarget } from "./targets";
import ContextPrompt from "./steps/0_context.mdx";
import ZigImplementPrompt from "./steps/1_implement.mdx";
import ZigTestPrompt from "./steps/2_test.mdx";
import ReviewPrompt from "./steps/3_review.mdx";
import ReviewFixPrompt from "./steps/4_review-fix.mdx";
import ReviewResponsePrompt from "./steps/4.5_review-response.mdx";
import ZigRefactorPrompt from "./steps/5_refactor.mdx";
import BenchmarkPrompt from "./steps/6_benchmark.mdx";
import FinalReviewPrompt from "./steps/7_final-review.mdx";
import EffectImplementPrompt from "./steps/effect/1_implement";
import EffectTestPrompt from "./steps/effect/2_test";
import EffectRefactorPrompt from "./steps/effect/5_refactor";

const MAX_PASSES = 5;
const MAX_ITERATIONS_PER_PASS = phases.length * 50;
const WORKFLOW_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(WORKFLOW_DIR, "../..");

const skipPhases = new Set(
  (process.env.SKIP_PHASES ?? "").split(",").map((s) => s.trim()).filter(Boolean)
);

type WorkItemType = "review" | "issue";
type PendingWorkItem = {
  sourceType: WorkItemType;
  sourcePath: string;
  absPath: string;
  mtimeMs: number;
};

const WORK_ITEM_SOURCES: ReadonlyArray<{ sourceType: WorkItemType; dir: string }> = [
  { sourceType: "review", dir: resolve(REPO_ROOT, "reviews") },
  { sourceType: "issue", dir: resolve(REPO_ROOT, "issues") },
  { sourceType: "review", dir: resolve(WORKFLOW_DIR, "reviews") },
  { sourceType: "issue", dir: resolve(WORKFLOW_DIR, "issues") },
];

function normalizeToken(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "");
}

function toRepoRelativePath(absPath: string): string {
  if (!isAbsolute(absPath)) return absPath;
  const rel = relative(REPO_ROOT, absPath);
  if (!rel.startsWith("..") && rel !== "") return rel.split("\\").join("/");
  return absPath;
}

function matchesPhase(filePath: string, phaseId: string, phaseName: string): boolean {
  const candidate = normalizeToken(filePath);
  const phaseIdToken = normalizeToken(phaseId);
  if (candidate.includes(phaseIdToken)) return true;

  const phaseNameToken = normalizeToken(phaseName);
  return phaseNameToken.length > 0 && candidate.includes(phaseNameToken);
}

function listWorkItems(sourceType: WorkItemType, dir: string): PendingWorkItem[] {
  if (!existsSync(dir)) return [];

  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && !entry.name.startsWith("."))
      .map((entry) => {
        const absPath = resolve(dir, entry.name);
        const stats = statSync(absPath);
        return {
          sourceType,
          sourcePath: toRepoRelativePath(absPath),
          absPath,
          mtimeMs: stats.mtimeMs,
        } as PendingWorkItem;
      })
      .sort((a, b) => a.mtimeMs - b.mtimeMs || a.sourcePath.localeCompare(b.sourcePath));
  } catch {
    return [];
  }
}

function findPendingWorkItem(phaseId: string, phaseName: string): PendingWorkItem | null {
  for (const source of WORK_ITEM_SOURCES) {
    const matches = listWorkItems(source.sourceType, source.dir).filter((item) =>
      matchesPhase(item.sourcePath, phaseId, phaseName)
    );
    if (matches.length > 0) return matches[0];
  }
  return null;
}

type ContextRow = typeof tables.context.$inferSelect;
type ImplementRow = typeof tables.implement.$inferSelect;
type TestRow = typeof tables.test_results.$inferSelect;
type ReviewRow = typeof tables.review.$inferSelect;
type ReviewFixRow = typeof tables.review_fix.$inferSelect;
type ReviewResponseRow = typeof tables.review_response.$inferSelect;
type BenchmarkRow = typeof tables.benchmark.$inferSelect;
type FinalReviewRow = typeof tables.final_review.$inferSelect;
type WorkItemRow = typeof tables.work_item.$inferSelect;
type WorkItemCleanupRow = typeof tables.work_item_cleanup.$inferSelect;
type OutputRow = typeof tables.output.$inferSelect;

type ImplementPromptProps = {
  phase: string;
  target: ReturnType<typeof getTarget>;
  contextFilePath: string;
  previousWork: ImplementRow | null;
  failingTests: string | null;
  reviewFixes: string | null;
  implementPass: number;
};

function renderImplementPrompt(targetId: string, props: ImplementPromptProps) {
  if (targetId === "effect") return EffectImplementPrompt(props);
  return <ZigImplementPrompt {...props} />;
}

function renderTestPrompt(targetId: string, props: { phase: string }) {
  if (targetId === "effect") return EffectTestPrompt(props);
  return <ZigTestPrompt {...props} />;
}

function renderRefactorPrompt(targetId: string, props: { phase: string }) {
  if (targetId === "effect") return EffectRefactorPrompt(props);
  return <ZigRefactorPrompt {...props} />;
}

export default smithers((ctx) => {
  const targetId = (ctx as any).input?.target ?? process.env.WORKFLOW_TARGET ?? "zig";
  const target = getTarget(targetId);
  const codex = makeCodex(target);

  const passTracker = ctx.latest(tables.output, "pass-tracker") as OutputRow | undefined;
  const currentPass = passTracker?.totalIterations ?? 0;

  const pendingWorkItemsByPhase = new Map(
    phases.map(({ id, name }) => [id, findPendingWorkItem(id, name)] as const)
  );

  const allPhasesComplete = phases.every(({ id }) => {
    const review = ctx.latest(tables.final_review, `${id}:final-review`) as FinalReviewRow | undefined;
    const hasPendingWorkItem = Boolean(pendingWorkItemsByPhase.get(id));
    return (review?.readyToMoveOn ?? false) && !hasPendingWorkItem;
  });

  const done = currentPass >= MAX_PASSES && allPhasesComplete;

  return (
    <Workflow name={`guillotine-build-${target.id}`}>
      <Ralph until={done} maxIterations={MAX_PASSES * MAX_ITERATIONS_PER_PASS} onMaxReached="return-last">
        <Sequence>
          {phases.map(({ id, name }) => {
            const phase = `[pass ${currentPass + 1}/${MAX_PASSES}] ${id} (${name})`;
            const pendingWorkItem = pendingWorkItemsByPhase.get(id) ?? null;

            const latestFinalReview = ctx.outputMaybe(tables.final_review, { nodeId: `${id}:final-review` }) as FinalReviewRow | undefined;
            const latestContext = ctx.outputMaybe(tables.context, { nodeId: `${id}:context` }) as ContextRow | undefined;
            const latestWorkItem = ctx.outputMaybe(tables.work_item, { nodeId: `${id}:work-item` }) as WorkItemRow | undefined;
            const latestWorkItemCleanup = ctx.outputMaybe(tables.work_item_cleanup, { nodeId: `${id}:work-item-cleanup` }) as WorkItemCleanupRow | undefined;
            const latestImplement1 = ctx.outputMaybe(tables.implement, { nodeId: `${id}:implement-1` }) as ImplementRow | undefined;
            const latestImplement2 = ctx.outputMaybe(tables.implement, { nodeId: `${id}:implement-2` }) as ImplementRow | undefined;
            const latestImplement = latestImplement2 ?? latestImplement1;
            const latestTest = ctx.outputMaybe(tables.test_results, { nodeId: `${id}:test` }) as TestRow | undefined;
            const latestReview = ctx.outputMaybe(tables.review, { nodeId: `${id}:review` }) as ReviewRow | undefined;
            const latestReviewFix = ctx.outputMaybe(tables.review_fix, { nodeId: `${id}:review-fix` }) as ReviewFixRow | undefined;
            const latestReviewResponse = ctx.outputMaybe(tables.review_response, { nodeId: `${id}:review-response` }) as ReviewResponseRow | undefined;
            const latestBenchmark = ctx.outputMaybe(tables.benchmark, { nodeId: `${id}:benchmark` }) as BenchmarkRow | undefined;

            const latestFinalReviewReady = latestFinalReview?.readyToMoveOn ?? false;
            const hasPendingWorkItem = Boolean(pendingWorkItem);
            const hasPendingCleanupForLatestWorkItem = Boolean(
              latestFinalReviewReady &&
              pendingWorkItem &&
              latestWorkItem &&
              latestWorkItem.sourcePath === pendingWorkItem.sourcePath &&
              latestWorkItem.sourceType === pendingWorkItem.sourceType &&
              latestWorkItemCleanup?.sourcePath !== latestWorkItem.sourcePath
            );
            const isPhaseComplete = latestFinalReviewReady && !hasPendingWorkItem;
            const isPhaseSkipped = skipPhases.has(id);
            const skipMainPhaseSequence = isPhaseSkipped || isPhaseComplete || hasPendingCleanupForLatestWorkItem;
            const contextFilePath =
              pendingWorkItem?.sourcePath ??
              latestWorkItem?.sourcePath ??
              latestContext?.contextFilePath ??
              `docs/context/${id}.md`;

            return (
              <Sequence key={id}>
                <Sequence skipIf={skipMainPhaseSequence}>
                  <Task id={`${id}:work-item`} output={tables.work_item} skipIf={!pendingWorkItem}>
                    {{
                      sourceType: pendingWorkItem?.sourceType ?? "review",
                      sourcePath: pendingWorkItem?.sourcePath ?? "",
                      summary: pendingWorkItem
                        ? `Using ${pendingWorkItem.sourceType} file ${pendingWorkItem.sourcePath} instead of context discovery.`
                        : "No external work item found.",
                    }}
                  </Task>

                  <Task id={`${id}:context`} output={tables.context} agent={codex} retries={2} skipIf={hasPendingWorkItem}>
                    <ContextPrompt
                      phase={phase}
                      target={target}
                      previousFeedback={latestFinalReview ?? null}
                      reviewFeedback={latestReview ?? null}
                      failingTests={latestTest && !latestTest.unitTestsPassed ? latestTest.failingSummary : null}
                    />
                  </Task>

                  {/* Implement pass 1 */}
                  <Task id={`${id}:implement-1`} output={tables.implement} agent={codex} retries={2}>
                    {renderImplementPrompt(target.id, {
                      phase,
                      target,
                      contextFilePath,
                      previousWork: latestImplement1 ?? null,
                      failingTests: latestTest?.failingSummary ?? null,
                      reviewFixes: latestReviewFix?.summary ?? null,
                      implementPass: 1,
                    })}
                  </Task>

                  {/* Implement pass 2 — builds on pass 1 output */}
                  <Task id={`${id}:implement-2`} output={tables.implement} agent={codex} retries={2}>
                    {renderImplementPrompt(target.id, {
                      phase,
                      target,
                      contextFilePath,
                      previousWork: latestImplement1 ?? null,
                      failingTests: latestTest?.failingSummary ?? null,
                      reviewFixes: latestReviewFix?.summary ?? null,
                      implementPass: 2,
                    })}
                  </Task>

                  <Task id={`${id}:test`} output={tables.test_results} agent={codex} retries={2}>
                    {renderTestPrompt(target.id, { phase })}
                  </Task>

                  <Task id={`${id}:review`} output={tables.review} agent={codex} retries={2}>
                    <ReviewPrompt
                      phase={phase}
                      target={target}
                      filesCreated={latestImplement?.filesCreated ?? []}
                      filesModified={latestImplement?.filesModified ?? []}
                      unitTests={latestTest?.unitTestsPassed ? "PASS" : "FAIL"}
                      specTests={latestTest?.specTestsPassed ? "PASS" : "FAIL"}
                      integrationTests={latestTest?.integrationTestsPassed ? "PASS" : "FAIL"}
                      nethermindDiff={latestTest?.nethermindDiffPassed ? "PASS" : "FAIL"}
                      failingSummary={latestTest?.failingSummary ?? null}
                    />
                  </Task>

                  <Task id={`${id}:review-fix`} output={tables.review_fix} agent={codex} retries={2} skipIf={latestReview?.severity === "none"}>
                    <ReviewFixPrompt
                      phase={phase}
                      target={target}
                      severity={latestReview?.severity ?? ""}
                      feedback={latestReview?.feedback ?? ""}
                      issues={latestReview?.issues ?? []}
                    />
                  </Task>

                  <Task id={`${id}:review-response`} output={tables.review_response} agent={codex} retries={2} skipIf={latestReview?.severity === "none"}>
                    <ReviewResponsePrompt
                      phase={phase}
                      target={target}
                      originalSeverity={latestReview?.severity ?? ""}
                      originalFeedback={latestReview?.feedback ?? ""}
                      originalIssues={latestReview?.issues ?? []}
                      fixesMade={latestReviewFix?.fixesMade ?? []}
                      fixSummary={latestReviewFix?.summary ?? ""}
                      fixCommitMessage={latestReviewFix?.commitMessage ?? ""}
                    />
                  </Task>

                  <Task id={`${id}:refactor`} output={tables.refactor} agent={codex} retries={2}>
                    {renderRefactorPrompt(target.id, { phase })}
                  </Task>

                  <Task id={`${id}:benchmark`} output={tables.benchmark} agent={codex} retries={2}>
                    <BenchmarkPrompt
                      phase={phase}
                      target={target}
                      filesCreated={latestImplement?.filesCreated ?? []}
                      filesModified={latestImplement?.filesModified ?? []}
                      whatWasDone={latestImplement?.whatWasDone ?? null}
                    />
                  </Task>

                  <Task id={`${id}:final-review`} output={tables.final_review} agent={codex} retries={2}>
                    <FinalReviewPrompt
                      phase={phase}
                      target={target}
                      unitTests={latestTest?.unitTestsPassed ? "PASS" : "FAIL"}
                      specTests={latestTest?.specTestsPassed ? "PASS" : "FAIL"}
                      integrationTests={latestTest?.integrationTestsPassed ? "PASS" : "FAIL"}
                      nethermindDiff={latestTest?.nethermindDiffPassed ? "PASS" : "FAIL"}
                      benchmarkStatus={latestBenchmark?.meetsTargets ? "MEETS TARGETS" : "BELOW TARGETS"}
                    />
                  </Task>
                </Sequence>

                <Task
                  id={`${id}:work-item-cleanup`}
                  output={tables.work_item_cleanup}
                  agent={codex}
                  retries={2}
                  skipIf={!hasPendingCleanupForLatestWorkItem}
                >
                  {`A ${latestWorkItem?.sourceType ?? "review"} work item was completed for ${id}. Delete this file if it exists:

${latestWorkItem?.sourcePath ?? ""}

Rules:
- If the file exists, remove it.
- If the file is already gone, do not fail.
- Do not modify any other files.
- Output ONLY JSON:
\`\`\`json
{
  "sourceType": "${latestWorkItem?.sourceType ?? "review"}",
  "sourcePath": "${latestWorkItem?.sourcePath ?? ""}",
  "removed": true,
  "summary": "what cleanup action occurred"
}
\`\`\`
`}
                </Task>
              </Sequence>
            );
          })}

          {/* After all phases complete a pass, record it and reset for next pass */}
          <Task id="pass-tracker" output={tables.output}>
            {{
              phasesCompleted: phases.map(({ id }) => id),
              totalIterations: currentPass + 1,
              summary: `Pass ${currentPass + 1} of ${MAX_PASSES} complete. ${currentPass + 1 < MAX_PASSES ? "Resetting all phases for next refinement pass." : "All passes complete."}`,
            }}
          </Task>
        </Sequence>
      </Ralph>
    </Workflow>
  );
});
