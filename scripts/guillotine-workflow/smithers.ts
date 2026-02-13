import { createSmithers } from "smithers-orchestrator";
import { outputSchemas } from "./db/schemas";

const dbTarget = process.env.WORKFLOW_TARGET ?? "zig";

export const { Workflow, Task, smithers, tables, db } = createSmithers(outputSchemas, {
  dbPath: `./${dbTarget}-guillotine.db`,
});
