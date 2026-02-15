export default function EffectTestTicketPrompt(props: {
  ticketId: string;
  ticketTitle: string;
  ticketCategory: string;
}): string {
  return `TESTING PHASE — Ticket: ${props.ticketId}

Title: ${props.ticketTitle}
Category: ${props.ticketCategory}

Run ALL of the following test categories and report results:

1. UNIT TESTS:
   Run: cd client-ts && bun run test
   Verify:
   - All Effect.gen compositions resolve correctly
   - Layer composition works
   - Error channels are properly typed and tested
   - Data.TaggedError instances are caught and matched correctly

2. SPEC TESTS (official Ethereum test vectors):
   Based on the category:
   - Phase 1 (trie): Run tests against ethereum-tests/TrieTests/ data
   - Phase 3 (evm-state): Use the phase-3 test gate script
   - Phase 4 (blockchain): Run against ethereum-tests/BlockchainTests/
   If no spec tests apply, note "N/A" but still run unit tests.

3. INTEGRATION TESTS:
   If there are integration tests, run them.
   Verify Layer composition across module boundaries.

4. NETHERMIND DIFFERENTIAL TESTS:
   If applicable, verify our output matches Nethermind's.

If any tests fail, fix and commit atomically:
- Format: "🐛 fix(SCOPE): what was fixed"
- After committing: git pull --rebase origin main && git push

`;
}
