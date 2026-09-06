"use client";

import { useEffect, useState } from "react";
import { HOST, PROVIDERS, SPINNER, STATUSES, location } from "@/lib/agents";
import { useDemo } from "./DemoProvider";

// telar's sidebar: the host on top, then one card per agent, three rows each
// as the sidebar contract specifies: title with status on the right,
// workspace › tab › pane, provider · abbreviated cwd. The provider mark is the
// same artwork the client embeds.
export default function Sidebar() {
  const { agents, focused, focusAgent } = useDemo();
  const [frame, setFrame] = useState(0);
  const spinning = agents.some((agent) => agent.status === "working");

  useEffect(() => {
    if (!spinning || window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      return;
    }

    const timer = window.setInterval(() => setFrame((value) => (value + 1) % SPINNER.length), 260);
    return () => window.clearInterval(timer);
  }, [spinning]);

  return (
    <aside className="attach hidden w-[19rem] shrink-0 flex-col border-r border-chrome-line bg-chrome-bg md:flex" style={{ ["--delay" as string]: "80ms" }}>
      <div className="flex items-center gap-2 px-4 pt-3 pb-4 font-mono text-[12px] text-chrome-text">
        <span className="text-chrome-overlay" aria-hidden="true">
          ⊖
        </span>
        {HOST}
      </div>

      <ul className="min-h-0 flex-1 overflow-y-auto px-2 pb-2 font-mono text-[12px] leading-[1.5]" aria-label="Agents">
        {agents.map((agent, index) => {
          const provider = PROVIDERS[agent.provider];
          const status = STATUSES[agent.status];
          const glyph = agent.status === "working" ? SPINNER[frame] : status.glyph;
          const isFocused = focused === agent.id;

          return (
            <li key={agent.id} className="repaint" style={{ ["--row" as string]: index + 1 }}>
              <button
                type="button"
                onClick={() => focusAgent(agent.id)}
                aria-current={isFocused ? "true" : undefined}
                className={`grid w-full grid-cols-[1.5rem_1fr] gap-x-1.5 rounded-md px-2 py-2.5 text-left ${isFocused ? "bg-chrome-panel" : "hover:bg-chrome-panel/60"}`}
              >
                <span className="pt-0.5">
                  <img src={provider.mark} alt="" width={14} height={14} className="rounded-[3px]" draggable={false} />
                </span>
                <span className="flex min-w-0 items-baseline justify-between gap-2">
                  <span className={`truncate font-medium text-chrome-text ${agent.generated ? "title-swap" : ""}`}>{agent.title}</span>
                  <span className={`flex shrink-0 items-center gap-1 ${status.tone}`}>
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
                <span className="truncate text-chrome-overlay">{location(agent)}</span>
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
