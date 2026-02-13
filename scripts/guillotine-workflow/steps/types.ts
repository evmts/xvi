import type { SmithersCtx } from "smithers-orchestrator";
import type { tables } from "../smithers";

export type Ctx = SmithersCtx<any>;

export type ContextRow = typeof tables.context.$inferSelect;
export type ImplementRow = typeof tables.implement.$inferSelect;
export type TestRow = typeof tables.test_results.$inferSelect;
export type ReviewRow = typeof tables.review.$inferSelect;
export type ReviewFixRow = typeof tables.review_fix.$inferSelect;
export type ReviewResponseRow = typeof tables.review_response.$inferSelect;
export type BenchmarkRow = typeof tables.benchmark.$inferSelect;
export type FinalReviewRow = typeof tables.final_review.$inferSelect;
export type OutputRow = typeof tables.output.$inferSelect;
