import type { SmithersCtx } from "smithers-orchestrator";
import type { tables } from "../smithers";

export type Ctx = SmithersCtx<any>;

export type CategoryReviewRow = typeof tables.category_review.$inferSelect;
export type DiscoverRow = typeof tables.discover.$inferSelect;
export type ResearchRow = typeof tables.research.$inferSelect;
export type PlanRow = typeof tables.plan.$inferSelect;
export type ImplementRow = typeof tables.implement.$inferSelect;
export type TestRow = typeof tables.test_results.$inferSelect;
export type BenchmarkRow = typeof tables.benchmark.$inferSelect;
export type SpecReviewRow = typeof tables.spec_review.$inferSelect;
export type CodeReviewRow = typeof tables.code_review.$inferSelect;
export type ReviewFixRow = typeof tables.review_fix.$inferSelect;
export type ReportRow = typeof tables.report.$inferSelect;
export type ProgressRow = typeof tables.progress.$inferSelect;
