"use client";

import { useEffect, useRef, useState } from "react";
import { PANES, panesOfTab, type Agent, type Line, type Pane } from "@/lib/agents";
import { useDemo } from "./DemoProvider";

// Vesper, whatever the chrome theme is: what runs inside a pane keeps its
// own colors.
const TONES: Record<NonNullable<Line["tone"]>, string> = {
  dim: "text-vesper-overlay",
  ok: "text-vesper-mint",
  warn: "text-vesper-peach",
  accent: "text-vesper-peach",
  prompt: "text-vesper-text",
  key: "text-vesper-peach",
};

type ScreenProps = { pane: Pane; agent?: Agent; focused: boolean; onFocus: () => void };

// One pane of the open tab: title on the border, the focus ring drawn again
// when it becomes focused, and lines arriving on the program's own clock
// from the first moment the pane is looked at.
function Screen({ pane, agent, focused, onFocus }: ScreenProps) {
  const lines = agent?.lines ?? pane.lines ?? [];
  const key = agent?.id ?? `${pane.tab}-${pane.number}`;
  const [shown, setShown] = useState<Record<string, number>>({});
  const count = shown[key] ?? 0;
  const scroller = useRef<HTMLPreElement>(null);

  // A terminal follows its own output: keep the newest line in view.
  useEffect(() => {
    const element = scroller.current;
    if (element) {
      element.scrollTop = element.scrollHeight;
    }
  }, [count]);

  useEffect(() => {
    if (count >= lines.length) {
      return;
    }

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setShown((current) => ({ ...current, [key]: lines.length }));
      return;
    }

    const previous = count > 0 ? lines[count - 1].at : 0;
    const timer = window.setTimeout(
      () => setShown((current) => ({ ...current, [key]: Math.max(current[key] ?? 0, count + 1) })),
      Math.max(40, lines[count].at - previous)
    );

    return () => window.clearTimeout(timer);
  }, [key, lines, count]);

  const finished = count >= lines.length;
  const showCursor = agent ? agent.status !== "working" || !finished : finished;
  // Agents wrap like a shell; an editor clips like nvim does.
  const wrap = agent ? "whitespace-pre-wrap" : "whitespace-pre";

  return (
    <section
      className={`relative min-w-0 rounded-[3px] border border-chrome-line bg-vesper-ink ${agent ? "flex-[2]" : "flex-[3]"}`}
      aria-label={`Pane ${pane.number}, ${pane.title}`}
      onPointerDown={onFocus}
    >
      {focused ? (
        <svg key={key} className="pane-ring pointer-events-none absolute inset-0 h-full w-full" aria-hidden="true">
          <rect x="0.5" y="0.5" width="calc(100% - 1px)" height="calc(100% - 1px)" pathLength={1} />
        </svg>
      ) : null}
      <span className={`absolute -top-2 left-3 z-10 bg-chrome-bg px-1.5 font-mono text-[11px] ${focused ? "text-chrome-accent" : "text-chrome-subtext"}`}>
        {pane.number} {pane.title}
      </span>
      <pre
        ref={scroller}
        className="h-full overflow-hidden rounded-[3px] p-4 pt-5 font-mono text-[12px] leading-[1.7] text-vesper-subtext"
        style={{ ["--cursor-color" as string]: "var(--vesper-peach)" }}
      >
        {lines.slice(0, count).map((line, index) => (
          <div key={index} className={`line-in ${wrap} ${line.tone ? TONES[line.tone] : ""}`}>
            {line.text || " "}
            {index === count - 1 && showCursor ? (
              <span className={finished ? "cursor" : "inline-block h-[1.05em] w-[0.55em] translate-y-[0.18em] bg-vesper-peach"} />
            ) : null}
          </div>
        ))}
      </pre>
    </section>
  );
}

// The open tab's panes side by side. The focused agent's pane carries the
// ring; clicking another agent's pane focuses that agent.
export default function Terminal() {
  const { agents, focused, focusAgent } = useDemo();
  const agent = agents.find((item) => item.id === focused) ?? agents[0];
  const panes = panesOfTab(agent.tab);

  return (
    <div className="flex h-full gap-3">
      {(panes.length ? panes : PANES.slice(0, 1)).map((pane) => {
        const paneAgent = pane.agent ? agents.find((item) => item.id === pane.agent) : undefined;
        return (
          <Screen
            key={`${pane.tab}-${pane.number}`}
            pane={pane}
            agent={paneAgent}
            focused={paneAgent ? paneAgent.id === focused : false}
            onFocus={() => paneAgent && focusAgent(paneAgent.id)}
          />
        );
      })}
    </div>
  );
}
