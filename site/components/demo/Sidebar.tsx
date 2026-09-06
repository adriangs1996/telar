"use client";

import { useEffect, useState } from "react";
import { PROVIDERS, SPINNER, STATUSES, WORKSPACE, location } from "@/lib/agents";
import { useDemo } from "./DemoProvider";

// Three rows per agent, as the sidebar contract specifies: title with status
// on the right, workspace › tab › pane, provider and abbreviated cwd.
export default function Sidebar() {
  const { agents, focused, focusAgent } = useDemo();
  const [frame, setFrame] = useState(0);
  const spinning = agents.some((agent) => agent.status === "working");
  const working = agents.filter((agent) => agent.status === "working").length;
  const blocked = agents.filter((agent) => agent.status === "blocked").length;

  useEffect(() => {
    if (!spinning || window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      return;
    }

    const timer = window.setInterval(() => setFrame((value) => (value + 1) % SPINNER.length), 260);
    return () => window.clearInterval(timer);
  }, [spinning]);

  return (
    <aside className="attach hidden w-[17rem] shrink-0 flex-col border-r border-chrome-line bg-chrome-panel md:flex" style={{ ["--delay" as string]: "80ms" }}>
      <div className="flex items-center justify-between px-4 pt-3 pb-2 font-mono text-[11px] tracking-[0.12em] text-chrome-overlay uppercase">
        <span>workspaces</span>
      </div>
      <ul className="px-2 font-mono text-[12px]">
        <li className="repaint flex items-center justify-between rounded-md bg-chrome-surface/60 px-2 py-1.5 text-chrome-text" style={{ ["--row" as string]: 0 }}>
          <span className="flex items-center gap-2">
            <span className="h-1.5 w-1.5 rounded-full bg-chrome-accent" />
            {WORKSPACE}
          </span>
          <span className="text-chrome-subtext">{agents.length}</span>
        </li>
        <li className="repaint flex items-center justify-between rounded-md px-2 py-1.5 text-chrome-subtext" style={{ ["--row" as string]: 1 }}>
          <span className="flex items-center gap-2">
            <span className="h-1.5 w-1.5 rounded-full bg-chrome-surface" />
            guruwalk
          </span>
          <span className="text-chrome-overlay">2</span>
        </li>
      </ul>

      <div className="mt-4 flex items-center justify-between px-4 pb-2 font-mono text-[11px] tracking-[0.12em] text-chrome-overlay uppercase">
        <span>agents</span>
        <span className="tracking-normal normal-case">
          {working} working{blocked ? ` · ${blocked} blocked` : ""}
        </span>
      </div>
      <ul className="min-h-0 flex-1 overflow-y-auto px-2 pb-2 font-mono text-[12px] leading-[1.45]" aria-label="Agents">
        {agents.map((agent, index) => {
          const provider = PROVIDERS[agent.provider];
          const status = STATUSES[agent.status];
          const glyph = agent.status === "working" ? SPINNER[frame] : status.glyph;
          const isFocused = focused === agent.id;

          return (
            <li key={agent.id} className="repaint" style={{ ["--row" as string]: index + 2 }}>
              <button
                type="button"
                onClick={() => focusAgent(agent.id)}
                aria-current={isFocused ? "true" : undefined}
                className={`grid w-full grid-cols-[1.25rem_1fr] gap-x-1 rounded-md px-2 py-2 text-left ${isFocused ? "bg-chrome-surface" : "hover:bg-chrome-bg"}`}
              >
                <span className={`${provider.tone} pt-px text-[13px]`} aria-hidden="true">
                  {provider.glyph}
                </span>
                <span className="flex min-w-0 items-baseline justify-between gap-2">
                  <span className={`truncate text-chrome-text ${agent.generated ? "title-swap" : ""}`}>{agent.title}</span>
                  <span className={`flex shrink-0 items-center gap-1 text-[11.5px] ${status.tone}`}>
                    {agent.rang ? (
                      <span className="ping-once text-chrome-teal" aria-hidden="true">
                        ♪
                      </span>
                    ) : null}
                    <span aria-hidden="true">{glyph}</span>
                    {status.label}
                  </span>
                </span>
                <span />
                <span className="truncate text-chrome-subtext">{location(agent)}</span>
                <span />
                <span className="truncate text-chrome-overlay">
                  {provider.name} · {agent.cwd}
                </span>
              </button>
            </li>
          );
        })}
      </ul>
    </aside>
  );
}
