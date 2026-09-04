"use client";

import { useEffect, useState } from "react";
import { PROVIDERS, SPINNER, STATUSES } from "@/lib/agents";
import { paneLocation } from "@/lib/panes";
import { useClient } from "./ClientProvider";

// Three rows per agent, as the sidebar contract specifies: title with status
// on the right, workspace › tab › pane, provider and abbreviated cwd.
export default function AgentList({ inline = false }: { inline?: boolean }) {
  const { agents, focused, focusPane, epoch } = useClient();
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
    <ul key={epoch} className="font-mono text-[12px] leading-[1.45]" aria-label="Agents">
      {agents.map((agent, index) => {
        const provider = PROVIDERS[agent.provider];
        const status = STATUSES[agent.status];
        const glyph = agent.status === "working" ? SPINNER[frame] : status.glyph;
        const isFocused = focused === agent.pane;

        return (
          <li key={agent.id} className="repaint px-2" style={{ ["--row" as string]: index + 2 }}>
            <button
              type="button"
              onClick={() => focusPane(agent.pane)}
              aria-current={isFocused ? "true" : undefined}
              className={`grid w-full grid-cols-[1.25rem_1fr] gap-x-1 rounded-md px-2 py-2 text-left transition-colors ${
                isFocused ? "bg-chrome-surface" : "hover:bg-chrome-panel"
              } ${inline ? "" : ""}`}
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
              <span className="truncate text-chrome-subtext">{paneLocation(agent.pane)}</span>
              <span />
              <span className="truncate text-chrome-overlay">
                {provider.name} · {agent.cwd}
              </span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}
