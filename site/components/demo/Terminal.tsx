"use client";

import { useEffect, useState } from "react";
import { PROVIDERS, type Line } from "@/lib/agents";
import { useDemo } from "./DemoProvider";

const TONES: Record<NonNullable<Line["tone"]>, string> = {
  dim: "text-overlay-1",
  ok: "text-mint",
  warn: "text-peach",
  accent: "text-peach",
  prompt: "text-text",
};

// The focused agent's pane. Lines arrive on the agent's own clock from the
// moment the pane is first looked at; the pane keeps Vesper whatever the
// chrome's theme is, because what runs inside a pane keeps its own colors.
export default function Terminal() {
  const { agents, focused } = useDemo();
  const agent = agents.find((item) => item.id === focused) ?? agents[0];
  const [shown, setShown] = useState<Record<string, number>>({});
  const count = shown[agent.id] ?? 0;

  useEffect(() => {
    if (count >= agent.lines.length) {
      return;
    }

    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) {
      setShown((current) => ({ ...current, [agent.id]: agent.lines.length }));
      return;
    }

    const next = agent.lines[count];
    const previous = count > 0 ? agent.lines[count - 1].at : 0;
    const timer = window.setTimeout(
      () => setShown((current) => ({ ...current, [agent.id]: Math.max(current[agent.id] ?? 0, count + 1) })),
      Math.max(80, next.at - previous)
    );

    return () => window.clearTimeout(timer);
  }, [agent, count]);

  const finished = count >= agent.lines.length;
  const provider = PROVIDERS[agent.provider];

  return (
    <section
      className="relative h-full rounded-[3px] border border-chrome-line bg-ink"
      aria-label={`Pane ${agent.pane}, ${provider.name}`}
    >
      <svg key={agent.id} className="pane-ring pointer-events-none absolute inset-0 h-full w-full" aria-hidden="true">
        <rect x="0.5" y="0.5" width="calc(100% - 1px)" height="calc(100% - 1px)" pathLength={1} />
      </svg>
      <span className="absolute -top-2 left-4 z-10 bg-chrome-bg px-1.5 font-mono text-[11px] text-chrome-accent">
        {agent.pane} {provider.name.toLowerCase().split(" ")[0]}
      </span>
      <span className="absolute -top-2 right-4 z-10 bg-chrome-bg px-1.5 font-mono text-[12px] text-chrome-subtext" aria-hidden="true">
        ⛶
      </span>
      <pre className="h-full overflow-y-auto rounded-[3px] p-5 pt-6 font-mono text-[12.5px] leading-[1.7] text-subtext">
        {agent.lines.slice(0, count).map((line, index) => (
          <div key={index} className={`line-in whitespace-pre-wrap ${line.tone ? TONES[line.tone] : ""}`}>
            {line.text}
            {index === count - 1 && (finished ? agent.status !== "working" : true) ? (
              <span className={finished ? "cursor" : "inline-block h-[1.05em] w-[0.55em] translate-y-[0.18em] bg-peach"} />
            ) : null}
          </div>
        ))}
      </pre>
    </section>
  );
}
