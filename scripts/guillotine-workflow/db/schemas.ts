import { z } from "zod";

// Simple Zod schemas for agent outputs (without runId, nodeId, iteration which smithers populates)

export const contextOutputSchema = z.object({
  contextFilePath: z.string().describe("Path to the context file created"),
  nethermindFiles: z.array(z.string()).nullable().describe("List of Nethermind reference files"),
  specFiles: z.array(z.string()).nullable().describe("List of spec files"),
  voltaireApis: z.array(z.string()).nullable().describe("List of Voltaire APIs to use"),
  existingZigFiles: z.array(z.string()).nullable().describe("List of existing Zig files"),
  testFixtures: z.array(z.string()).nullable().describe("List of test fixture paths"),
  summary: z.string().describe("Summary of what was gathered"),
});

export const implementOutputSchema = z.object({
  filesCreated: z.array(z.string()).nullable().describe("Files that were created"),
  filesModified: z.array(z.string()).nullable().describe("Files that were modified"),
  commitMessage: z.string().describe("Commit message for the implementation"),
  whatWasDone: z.string().describe("Description of what was implemented"),
  nextSmallestUnit: z.string().describe("Next smallest unit of work to implement"),
});

export const testOutputSchema = z.object({
  unitTestsPassed: z.boolean().describe("Whether unit tests passed"),
  specTestsPassed: z.boolean().describe("Whether spec tests passed"),
  integrationTestsPassed: z.boolean().describe("Whether integration tests passed"),
  nethermindDiffPassed: z.boolean().describe("Whether Nethermind differential tests passed"),
  failingSummary: z.string().nullable().describe("Summary of failing tests"),
  testOutput: z.string().describe("Full test output"),
});

export const reviewOutputSchema = z.object({
  issues: z.array(z.string()).nullable().describe("List of issues found"),
  severity: z.enum(["critical", "major", "minor", "none"]).describe("Severity of issues"),
  feedback: z.string().describe("Overall review feedback"),
});

export const reviewFixOutputSchema = z.object({
  fixesMade: z.array(z.string()).nullable().describe("List of fixes made"),
  commitMessage: z.string().describe("Commit message for fixes"),
  summary: z.string().describe("Summary of fixes"),
});

export const reviewResponseOutputSchema = z.object({
  fixesAccepted: z.boolean().describe("Whether fixes were accepted"),
  remainingIssues: z.array(z.string()).nullable().describe("Remaining issues if any"),
  feedback: z.string().describe("Feedback on the fixes"),
});

export const refactorOutputSchema = z.object({
  changesDescription: z.string().describe("Description of refactoring changes"),
  commitMessage: z.string().describe("Commit message for refactoring"),
  filesChanged: z.array(z.string()).nullable().describe("Files that were changed"),
});

export const benchmarkOutputSchema = z.object({
  results: z.string().describe("Benchmark results"),
  meetsTargets: z.boolean().describe("Whether performance targets are met"),
  suggestions: z.string().nullable().describe("Performance improvement suggestions"),
});

export const finalReviewOutputSchema = z.object({
  readyToMoveOn: z.boolean().describe("Whether the phase is complete"),
  remainingIssues: z.array(z.string()).nullable().describe("Remaining issues if any"),
  reasoning: z.string().describe("Reasoning for the decision"),
});

export const workItemOutputSchema = z.object({
  sourceType: z.enum(["review", "issue"]).describe("Type of external work item"),
  sourcePath: z.string().describe("Path to external review/issue file"),
  summary: z.string().describe("Why this external work item was used"),
});

export const workItemCleanupOutputSchema = z.object({
  sourceType: z.enum(["review", "issue"]).describe("Type of external work item"),
  sourcePath: z.string().describe("Path to external review/issue file"),
  removed: z.boolean().describe("Whether the file was removed"),
  summary: z.string().describe("Cleanup result"),
});

export const outputOutputSchema = z.object({
  phasesCompleted: z.array(z.string()).nullable().describe("List of phases completed in this pass"),
  totalIterations: z.number().int().describe("Total passes completed"),
  summary: z.string().describe("Pass summary"),
});

// Map table names to their output schemas
export const outputSchemas = {
  context: contextOutputSchema,
  implement: implementOutputSchema,
  test_results: testOutputSchema,
  review: reviewOutputSchema,
  review_fix: reviewFixOutputSchema,
  review_response: reviewResponseOutputSchema,
  refactor: refactorOutputSchema,
  benchmark: benchmarkOutputSchema,
  final_review: finalReviewOutputSchema,
  work_item: workItemOutputSchema,
  work_item_cleanup: workItemCleanupOutputSchema,
  output: outputOutputSchema,
} satisfies Record<string, z.ZodObject<any>>;
