import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import type { Ticket } from "../db/schemas";
import BenchmarkPrompt from "../steps/benchmark-ticket.mdx";

type BenchmarkProps = {
  target: Target;
  ticket: Ticket;
  filesCreated: string[] | null;
  filesModified: string[] | null;
  whatWasDone: string | null;
};

export function Benchmark({ target, ticket, filesCreated, filesModified, whatWasDone }: BenchmarkProps) {
  const agent = makeClaude(target);

  return (
    <Task id={`${ticket.id}:benchmark`} output={tables.benchmark} agent={agent} retries={2}>
      <BenchmarkPrompt
        ticketId={ticket.id}
        ticketTitle={ticket.title}
        ticketCategory={ticket.category}
        filesCreated={filesCreated}
        filesModified={filesModified}
        whatWasDone={whatWasDone}
      />
    </Task>
  );
}
