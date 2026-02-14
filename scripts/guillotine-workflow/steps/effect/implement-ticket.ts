export default function EffectImplementTicketPrompt(props: {
  ticketId: string;
  ticketTitle: string;
  ticketCategory: string;
  planFilePath: string;
  contextFilePath: string;
  implementationSteps: string[] | null;
  previousImplementation: { whatWasDone: string; nextSteps: string | null } | null;
  reviewFeedback: string | null;
  failingTests: string | null;
}): string {
  return `IMPLEMENTATION PHASE — Ticket: ${props.ticketId}

Title: ${props.ticketTitle}
Category: ${props.ticketCategory}

## Context

Read the plan file: ${props.planFilePath}
Read the context file: ${props.contextFilePath}

Implementation steps from plan:
${props.implementationSteps ? props.implementationSteps.map((s, i) => `${i + 1}. ${s}`).join('\n') : 'See plan file'}

${props.previousImplementation ? `\nPrevious implementation attempt:\nWhat was done: ${props.previousImplementation.whatWasDone}\nNext steps: ${props.previousImplementation.nextSteps ?? 'None specified'}` : ''}

${props.reviewFeedback ? `\nReview feedback to address:\n${props.reviewFeedback}` : ''}

${props.failingTests ? `\nFIX THESE FAILING TESTS FIRST:\n${props.failingTests}` : ''}

## Rules

- Implement the SMALLEST ATOMIC UNIT of work possible — one service, one function, one interface
- Use Effect Context.Tag + Layer dependency injection pattern
- Import from voltaire-effect — NEVER create custom types
- Read the Nethermind equivalent code first, then implement in idiomatic Effect.ts
- After implementing: cd client-ts && bun run build && bun test
- Write @effect/vitest it.effect() tests for every public function
- Use Effect.gen(function* () { ... }) for sequential composition
- Use Data.TaggedError for all domain errors
- NEVER use Effect.runPromise except at app edge
- Use 'satisfies' to type-check service implementations

## GIT COMMIT RULES
- Make atomic commits — one logical change per commit
- Use emoji prefixes: 🐛 fix, ♻️ refactor, 🧪 test, ⚡ perf
- After committing: git pull --rebase origin main && git push

**REQUIRED OUTPUT:**
\`\`\`json
{
  "filesCreated": ["client-ts/path/to/new_file.ts"],
  "filesModified": ["client-ts/existing_file.ts"],
  "commitMessage": "♻️ refactor(scope): Description",
  "whatWasDone": "Detailed description of what was implemented",
  "nextSteps": "What still needs to be done, or null if complete"
}
\`\`\``;
}
