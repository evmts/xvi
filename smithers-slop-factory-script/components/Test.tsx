import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import ZigTestPrompt from "../steps/test-ticket.mdx";
import EffectTestPrompt from "../steps/effect/test-ticket";

type TestProps = {
  target: Target;
  ticket: Ticket;
};

export function Test({ target, ticket }: TestProps) {
  const agent = makeClaude(target);

  const promptProps = {
    ticketId: ticket.id,
    ticketTitle: ticket.title,
    ticketCategory: ticket.category,
  };

  return (
    <Task id={`${ticket.id}:test`} output={tables.test_results} agent={agent} retries={2}>
      {target.id === "effect"
        ? EffectTestPrompt(promptProps)
        : <ZigTestPrompt {...promptProps} />}
    </Task>
  );
}
