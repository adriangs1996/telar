import Story from "./Story";

const paths = [
  {
    name: "Interactive",
    carries: "A keystroke to the child. A byte of output to a glyph.",
    budget: "Microseconds. Allocates nothing. Frames are capped at 60 Hz and what does not fit is folded, never queued.",
    lane: "fast",
  },
  {
    name: "Media",
    carries: "Kitty graphics payloads, decoded images, image transfer.",
    budget: "Frame deadlines. Strict quotas behind bounded queues. A newer frame replaces the one still in flight.",
    lane: "frame",
  },
  {
    name: "Observation",
    carries: "What an agent did: the tool it called, what it asked, what came back.",
    budget: "Before you search for it. May allocate, may block, may be slow. Never in the way of the other two.",
    lane: "slow",
  },
];

export default function Paths() {
  return (
    <Story
      wide
      title="Three paths, three budgets."
      intro={
        <p>
          Telar sits between your terminal and the pty, and between the agent and the network. Doing a lot of work
          there is only acceptable if you never feel it. Each path has its own budget and never waits on another.
        </p>
      }
    >
      <ul className="divide-y divide-line border-y border-line">
        {paths.map((path) => (
          <li key={path.name} className="grid gap-3 py-6 md:grid-cols-[8rem_1fr]">
            <div className="font-mono text-[14px] text-text">{path.name}</div>
            <div>
              <p className="text-text">{path.carries}</p>
              <p className="mt-1 text-subtext">{path.budget}</p>
              <div className="relative mt-5 h-[3px] overflow-hidden rounded-full bg-surface-1" aria-hidden="true">
                {path.lane === "fast" ? <div className="lane-fast absolute inset-0" /> : null}
                {path.lane === "frame" ? <div className="lane-frame absolute top-0 h-full w-[12%] rounded-full bg-mauve" /> : null}
                {path.lane === "slow" ? <div className="lane-slow absolute top-0 h-full w-[30%] rounded-full bg-teal" /> : null}
              </div>
            </div>
          </li>
        ))}
      </ul>
    </Story>
  );
}
