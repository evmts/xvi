import { Task, tables } from "../smithers";
import { makeClaude } from "../agents/claude";
import type { Target } from "../targets";
import UpdateProgressPrompt from "../steps/update-progress.mdx";

type UpdateProgressProps = {
  target: Target;
  completedTickets: string[];
};

export function UpdateProgress({ target, completedTickets }: UpdateProgressProps) {
  const agent = makeClaude(target);

  return (
    <Task id="update-progress" output={tables.progress} agent={agent} retries={2}>
      <UpdateProgressPrompt completedTickets={completedTickets} />
    </Task>
  );
}
