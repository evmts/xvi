import { z } from "zod";

// --- Ticket schema (used by Discover, referenced by all pipeline steps) ---

export const ticketSchema = z.object({
  id: z.string().describe("Kebab-case slug, e.g. 'fix-sstore-gas-metering'"),
  title: z.string().describe("Short descriptive title"),
  description: z.string().describe("Detailed description of what needs to be done"),
  category: z.string().describe("Category from the categories list (e.g. phase-0-db)"),
  priority: z.enum(["critical", "high", "medium", "low"]).describe("Priority — review tickets are typically critical/high"),
  ticketType: z.enum(["review", "feature"]).describe("Whether this is a review of past work or new feature work"),
  acceptanceCriteria: z.array(z.string()).describe("List of criteria that must be met"),
  testPlan: z.string().describe("How to verify this ticket is complete"),
  estimatedComplexity: z.enum(["trivial", "small", "medium", "large"]).describe("Estimated complexity"),
  dependencies: z.array(z.string()).nullable().describe("Ticket IDs this depends on"),
  relevantFiles: z.array(z.string()).nullable().describe("Files in our codebase to modify"),
  referenceFiles: z.array(z.string()).nullable().describe("Reference files (Nethermind, specs, Voltaire)"),
});

export type Ticket = z.infer<typeof ticketSchema>;

// --- Codebase review schema (per-category deep review of past work) ---

export const categoryReviewOutputSchema = z.object({
  categoryId: z.string().describe("Category ID that was reviewed"),
  categoryName: z.string().describe("Category name"),
  specCompliance: z.object({
    issues: z.array(z.string()).nullable().describe("Spec compliance issues found"),
    severity: z.enum(["critical", "major", "minor", "none"]).describe("Worst severity"),
    feedback: z.string().describe("Spec compliance summary"),
  }),
  nethermindAlignment: z.object({
    issues: z.array(z.string()).nullable().describe("Architecture deviations from Nethermind"),
    severity: z.enum(["critical", "major", "minor", "none"]).describe("Worst severity"),
    feedback: z.string().describe("Nethermind alignment summary"),
  }),
  testCoverage: z.object({
    issues: z.array(z.string()).nullable().describe("Test coverage gaps"),
    severity: z.enum(["critical", "major", "minor", "none"]).describe("Worst severity"),
    feedback: z.string().describe("Test coverage summary"),
  }),
  codeQuality: z.object({
    issues: z.array(z.string()).nullable().describe("Code quality issues"),
    severity: z.enum(["critical", "major", "minor", "none"]).describe("Worst severity"),
    feedback: z.string().describe("Code quality summary"),
  }),
  voltaireUsage: z.object({
    issues: z.array(z.string()).nullable().describe("Voltaire integration issues"),
    severity: z.enum(["critical", "major", "minor", "none"]).describe("Worst severity"),
    feedback: z.string().describe("Voltaire usage summary"),
  }),
  overallSeverity: z.enum(["critical", "major", "minor", "none"]).describe("Worst severity across all dimensions"),
  suggestedTickets: z.array(ticketSchema).describe("Review tickets generated from findings"),
});

// --- Output schemas for each pipeline step ---

export const discoverOutputSchema = z.object({
  tickets: z.array(ticketSchema).describe("New feature tickets for remaining work"),
  reasoning: z.string().describe("Why these tickets were chosen"),
  completionEstimate: z.string().describe("Overall completion estimate for the project"),
});

export const researchOutputSchema = z.object({
  ticketId: z.string().describe("ID of the ticket being researched"),
  nethermindFiles: z.array(z.string()).nullable().describe("Relevant Nethermind reference files"),
  specFiles: z.array(z.string()).nullable().describe("Relevant execution-specs Python files"),
  voltaireApis: z.array(z.string()).nullable().describe("Voltaire APIs to use"),
  existingFiles: z.array(z.string()).nullable().describe("Existing codebase files to modify/reference"),
  testFixtures: z.array(z.string()).nullable().describe("Test fixture paths"),
  contextFilePath: z.string().describe("Path to the written context file"),
  summary: z.string().describe("Summary of research findings"),
});

export const planOutputSchema = z.object({
  ticketId: z.string().describe("ID of the ticket being planned"),
  implementationSteps: z.array(z.string()).describe("Ordered steps to implement"),
  filesToCreate: z.array(z.string()).nullable().describe("New files to create"),
  filesToModify: z.array(z.string()).nullable().describe("Existing files to modify"),
  testsToWrite: z.array(z.string()).nullable().describe("Tests to write"),
  risks: z.array(z.string()).nullable().describe("Potential risks or concerns"),
  planFilePath: z.string().describe("Path to the written plan file"),
});

export const implementOutputSchema = z.object({
  filesCreated: z.array(z.string()).nullable().describe("Files that were created"),
  filesModified: z.array(z.string()).nullable().describe("Files that were modified"),
  commitMessage: z.string().describe("Commit message for the implementation"),
  whatWasDone: z.string().describe("Description of what was implemented"),
  nextSteps: z.string().nullable().describe("Next steps if work is incomplete"),
});

export const testOutputSchema = z.object({
  unitTestsPassed: z.boolean().describe("Whether unit tests passed"),
  specTestsPassed: z.boolean().describe("Whether spec tests passed"),
  integrationTestsPassed: z.boolean().describe("Whether integration tests passed"),
  nethermindDiffPassed: z.boolean().describe("Whether Nethermind differential tests passed"),
  failingSummary: z.string().nullable().describe("Summary of failing tests"),
  testOutput: z.string().describe("Full test output"),
});

export const benchmarkOutputSchema = z.object({
  ticketId: z.string().describe("ID of the ticket being benchmarked"),
  results: z.string().describe("Benchmark results"),
  meetsTargets: z.boolean().describe("Whether performance targets are met"),
  suggestions: z.string().nullable().describe("Performance improvement suggestions"),
});

export const specReviewOutputSchema = z.object({
  issues: z.array(z.string()).nullable().describe("Issues found vs execution-specs/Nethermind/EIPs"),
  severity: z.enum(["critical", "major", "minor", "none"]).describe("Severity of spec compliance issues"),
  feedback: z.string().describe("Detailed spec compliance feedback"),
  specFilesChecked: z.array(z.string()).nullable().describe("Which spec files were checked"),
});

export const codeReviewOutputSchema = z.object({
  issues: z.array(z.string()).nullable().describe("Code quality issues found"),
  severity: z.enum(["critical", "major", "minor", "none"]).describe("Severity of code quality issues"),
  feedback: z.string().describe("Overall code quality feedback"),
  testCoverage: z.string().nullable().describe("Assessment of test coverage"),
  codeQuality: z.string().nullable().describe("Assessment of code quality"),
});

export const reviewFixOutputSchema = z.object({
  fixesMade: z.array(z.string()).nullable().describe("List of fixes made"),
  falsePositiveComments: z.array(z.string()).nullable().describe("Issues marked as false positives with justification"),
  commitMessages: z.array(z.string()).nullable().describe("Commit messages for fixes"),
  allIssuesResolved: z.boolean().describe("Whether all issues are resolved"),
  summary: z.string().describe("Summary of fixes applied"),
});

export const reportOutputSchema = z.object({
  ticketId: z.string().describe("ID of the completed ticket"),
  status: z.enum(["complete", "partial", "blocked"]).describe("Ticket completion status"),
  summary: z.string().describe("What was accomplished"),
  filesChanged: z.array(z.string()).nullable().describe("All files changed"),
  testsAdded: z.array(z.string()).nullable().describe("Tests added"),
  reviewRounds: z.number().int().describe("How many review rounds were needed"),
  struggles: z.string().nullable().describe("What was difficult"),
  lessonsLearned: z.string().nullable().describe("Insights for future tickets"),
});

export const progressOutputSchema = z.object({
  progressFilePath: z.string().describe("Path to PROGRESS.md"),
  summary: z.string().describe("Summary of current progress"),
  ticketsCompleted: z.array(z.string()).nullable().describe("Ticket IDs completed so far"),
  ticketsRemaining: z.array(z.string()).nullable().describe("Ticket IDs still pending"),
});

export const integrationTestOutputSchema = z.object({
  categoryId: z.string(),
  status: z.enum(["not-started", "blocked", "partially-setup", "running", "passing"]),
  progressMade: z.string().describe("What was accomplished this iteration"),
  suitesAttempted: z.array(z.string()).describe("Which test suites were attempted"),
  blockers: z.array(z.string()).describe("What's preventing further progress — agent-solvable"),
  needsHumanIntervention: z.array(z.string()).nullable().describe("Blockers that require human action (install Docker, API keys, CI config, large downloads, etc.)"),
  suggestedTickets: z.array(z.string()).describe("Ticket ideas that would unblock testing"),
  findingsFilePath: z.string().describe("Path to docs/test-suite-findings.md"),
});

// Map table names to their output schemas
export const outputSchemas = {
  category_review: categoryReviewOutputSchema,
  discover: discoverOutputSchema,
  research: researchOutputSchema,
  plan: planOutputSchema,
  implement: implementOutputSchema,
  test_results: testOutputSchema,
  benchmark: benchmarkOutputSchema,
  spec_review: specReviewOutputSchema,
  code_review: codeReviewOutputSchema,
  review_fix: reviewFixOutputSchema,
  report: reportOutputSchema,
  progress: progressOutputSchema,
  integration_test: integrationTestOutputSchema,
} satisfies Record<string, z.ZodObject<any>>;
