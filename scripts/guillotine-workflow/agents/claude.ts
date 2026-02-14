import { ToolLoopAgent as Agent, stepCountIs } from "ai";
import { anthropic } from "@ai-sdk/anthropic";
import { ClaudeCodeAgent } from "smithers-orchestrator";
import { read, edit, bash, grep, write } from "smithers-orchestrator/tools";
import type { Target } from "../targets";
import { ZIG_TARGET } from "../targets";

const CLAUDE_MODEL = process.env.CLAUDE_MODEL ?? "claude-opus-4-6";
const USE_CLI = process.env.USE_CLI_AGENTS !== "0" && process.env.USE_CLI_AGENTS !== "false";
const REPO_ROOT = new URL("../../..", import.meta.url).pathname.replace(/\/$/, "");

export function getInstructions(target: Target): string {
  if (target.id === "effect") {
    return `We are building an Ethereum execution client in Effect.ts (TypeScript).
You have access to the full codebase and all reference materials.
All reference materials are in submodules.
You ALWAYS use voltaire-effect primitives (${target.importStyle}) — NEVER create custom Address/Hash/Hex types.
You ALWAYS use the existing guillotine-mini EVM (in src/) as reference for EVM behavior — the Effect client wraps it or reimplements in idiomatic Effect.ts.
You follow Nethermind's architecture (in nethermind/) as a structural reference but implement idiomatically in Effect.ts.
You use ${target.diPattern}.
You write small, atomic, testable units of code. One service or one function per commit.
You run ${target.fmtCmd} and ${target.buildCmd} after every change.
You test with ${target.testPattern}.
When implementing, you read the relevant spec files first (execution-specs/, EIPs/, devp2p/) before writing any code.
You can reference the Effect.ts source in effect-repo/ for API patterns.

GIT RULES — CRITICAL:
- NEVER create branches. Always commit directly to the current branch.
- NEVER run git checkout -b, git branch, or git switch -c.
- NEVER commit .db files, .sqlite files, or any database files.
- After committing, run git pull --rebase origin main to rebase on top of latest changes, then git push to push your changes to main.
- Just git add, git commit, git pull --rebase origin main, and git push on the current branch. That's it.

KEY EFFECT.TS RULES:
- NEVER use Effect.runPromise except at application edge (main entry, benchmarks)
- Use Effect.gen(function* () { ... }) for sequential composition
- Define services as Context.Tag — never use global mutable state
- Use Layer for DI — Layer.succeed, Layer.effect, Layer.scoped
- Type error channels — never use Effect<A, never, R> when errors are possible
- Use Data.TaggedError for all domain errors
- Use voltaire-effect primitives — Address, Hash, Hex from the library
- Test with @effect/vitest — it.effect() for Effect-returning tests
- Use 'satisfies' to type-check service implementations
- Proper resource management — Effect.acquireRelease for cleanup

CRITICAL OUTPUT REQUIREMENT:
When you have completed your work, you MUST end your response with a JSON object
wrapped in a code fence. The JSON format is specified in your task prompt.
Example:
\`\`\`json
{"key": "value", "other": "data"}
\`\`\`
This JSON output is REQUIRED. The workflow cannot continue without it.
ALWAYS include the JSON at the END of your final response.`;
  }

  return `We are building an Ethereum execution client in Zig.
You have access to the full codebase and all reference materials
All reference materials are in submodules
You ALWAYS use Voltaire primitives (from voltaire/packages/voltaire-zig/) — never create custom types.
You ALWAYS use the existing guillotine-mini EVM (in src/) — never reimplement the EVM.
You follow Nethermind's architecture (in nethermind/) as a structural reference but implement idiomatically in Zig.
You use comptime dependency injection patterns similar to the existing EVM code.
You write small, atomic, testable units of code. One function or one struct per commit.
You run zig fmt and zig build after every change.
When implementing, you read the relevant spec files first (execution-specs/, EIPs/, devp2p/) before writing any code.

GIT RULES — CRITICAL:
- NEVER create branches. Always commit directly to the current branch.
- NEVER run git checkout -b, git branch, or git switch -c.
- NEVER commit .db files, .sqlite files, or any database files.
- After committing, run git pull --rebase origin main to rebase on top of latest changes, then git push to push your changes to main.
- Just git add, git commit, git pull --rebase origin main, and git push on the current branch. That's it.

CRITICAL OUTPUT REQUIREMENT:
When you have completed your work, you MUST end your response with a JSON object
wrapped in a code fence. The JSON format is specified in your task prompt.
Example:
\`\`\`json
{"key": "value", "other": "data"}
\`\`\`
This JSON output is REQUIRED. The workflow cannot continue without it.
ALWAYS include the JSON at the END of your final response.`;
}

// Backward compat
export const WHAT_WE_ARE_DOING = getInstructions(ZIG_TARGET);

function getClaudeInstructions(target: Target): string {
  const base = getInstructions(target);
  const checklist = target.reviewChecklist.map((item, i) => `${i + 1}. ${item}`).join("\n");

  return `${base}

You are a ruthless, meticulous code reviewer for a high-performance Ethereum execution client in ${target.id === "effect" ? "Effect.ts" : "Zig"}.
You review code for:
${checklist}
You are EXTREMELY strict. If something can be improved, it MUST be flagged.

CRITICAL OUTPUT REQUIREMENT:
When you have completed your review, you MUST end your response with a JSON object
wrapped in a code fence. The JSON format is specified in your task prompt.
Example:
\`\`\`json
{"key": "value", "other": "data"}
\`\`\`
This JSON output is REQUIRED. The workflow cannot continue without it.
ALWAYS include the JSON at the END of your final response.`;
}

export function makeClaude(target: Target) {
  const instructions = getClaudeInstructions(target);

  const apiAgent = new Agent({
    model: anthropic(CLAUDE_MODEL),
    tools: { read, edit, bash, grep, write },
    instructions,
    stopWhen: stepCountIs(100),
    maxOutputTokens: 8192,
  });

  const cliAgent = new ClaudeCodeAgent({
    model: CLAUDE_MODEL,
    systemPrompt: instructions,
    dangerouslySkipPermissions: true,
    cwd: REPO_ROOT,
    timeoutMs: 60 * 60 * 1000, // 60 minutes max per task
  });

  return USE_CLI ? cliAgent : apiAgent;
}

export const claude = makeClaude(ZIG_TARGET);
