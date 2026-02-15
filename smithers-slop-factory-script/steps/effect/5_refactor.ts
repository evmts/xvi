export default function EffectRefactorPrompt(props: { phase: string }): string {
  return `REFACTORING PHASE: ${props.phase}

Review all code written in this phase for:
1. Code duplication — extract shared helpers
2. Layer composition — use Layer.merge, Layer.provide for clean DI graphs
3. Effect.gen vs pipe — use gen for complex logic, pipe for short chains
4. Public API surface — export service Tags + convenience accessors, keep internals private
5. Documentation — JSDoc comments on all public APIs
6. Import organization — clean up unused imports
7. Dead code — remove any unused functions or types
8. Consistent error handling — Data.TaggedError everywhere
9. No 'any' types — leverage Effect's type inference
10. Naming: PascalCase for types/services/tags, camelCase for functions/variables

Make improvements. Run cd client-ts && bun run build && bun test after each change.

GIT COMMIT RULES:
- Make atomic commits — one refactor per commit
- Use emoji prefixes: ♻️ refactor, 🐛 fix, 🧪 test, ⚡ perf
- Format: "EMOJI type(scope): description"
- Examples:
  - "♻️ refactor(phase-0-db): consolidate Layer composition with Layer.merge"
  - "♻️ refactor(phase-0-db): replace pipe chain with Effect.gen for readability"
- git add the specific files changed, then git commit with the emoji message
- After committing, run: git pull --rebase origin main && git push
- Always rebase before pushing to avoid merge commits

If nothing needs refactoring, say so and move on.

`;
}
