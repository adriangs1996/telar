const LANES = [
  {
    name: "interactive",
    carries: "A keystroke to the child. A byte of output to a glyph.",
    budget: "Microseconds. Allocates nothing. Frames capped at 60 Hz; what does not fit is folded, never queued.",
    lane: "fast",
  },
  {
    name: "media",
    carries: "Kitty graphics payloads, decoded images, image transfer.",
    budget: "Frame deadlines. Strict quotas behind bounded queues. A newer frame replaces the one still in flight.",
    lane: "frame",
  },
  {
    name: "observation",
    carries: "What an agent did: the tool it called, what it asked, what came back.",
    budget: "Before you search for it. May allocate, may block, may be slow. Never in the way of the other two.",
    lane: "slow",
  },
];

export default function Lanes() {
  return (
    <div className="figure divide-y divide-line">
      {LANES.map((path) => (
        <div key={path.name} className="grid gap-3 p-5 md:grid-cols-[7.5rem_1fr] md:p-6">
          <div className="font-mono text-[13px] text-text">{path.name}</div>
          <div>
            <p className="text-[15px] text-text">{path.carries}</p>
            <p className="mt-1 text-[14px] text-subtext">{path.budget}</p>
            <div className="relative mt-4 h-[3px] overflow-hidden rounded-full bg-surface-1" aria-hidden="true">
              {path.lane === "fast" ? <div className="lane-fast absolute inset-0" /> : null}
              {path.lane === "frame" ? <div className="lane-frame absolute top-0 h-full w-[12%] rounded-full bg-mauve" /> : null}
              {path.lane === "slow" ? <div className="lane-slow absolute top-0 h-full w-[30%] rounded-full bg-teal" /> : null}
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}
