import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import ZigImplementPrompt from "../steps/implement-ticket.mdx";
import EffectImplementPrompt from "../steps/effect/implement-ticket";

type ImplementProps = {
  target: Target;
  ticket: Ticket;
  planFilePath: string;
  contextFilePath: string;
  implementationSteps: string[] | null;
  previousImplementation: { whatWasDone: string; nextSteps: string | null } | null;
  reviewFeedback: string | null;
  failingTests: string | null;
};

export function Implement({
  target,
  ticket,
  planFilePath,
  contextFilePath,
  implementationSteps,
  previousImplementation,
  reviewFeedback,
  failingTests,
}: ImplementProps) {
  const agent = makeClaude(target);

  const promptProps = {
    ticketId: ticket.id,
    ticketTitle: ticket.title,
    ticketCategory: ticket.category,
    planFilePath,
    contextFilePath,
    implementationSteps,
    previousImplementation,
    reviewFeedback,
    failingTests,
  };

  return (
    <Task id={`${ticket.id}:implement`} output={tables.implement} agent={agent} retries={2}>
      {target.id === "effect"
        ? EffectImplementPrompt(promptProps)
        : <ZigImplementPrompt {...promptProps} />}
    </Task>
  );
}
