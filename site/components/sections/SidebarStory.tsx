"use client";

import AgentList from "@/components/client/AgentList";
import { STATUSES, type AgentStatus } from "@/lib/agents";
import Story from "./Story";

const ORDER: AgentStatus[] = ["working", "blocked", "done", "ready"];

export default function SidebarStory() {
  return (
    <Story
      wide
      title="One sidebar that knows what every agent is doing."
      intro={
        <>
          <p>
            Every card in telar&apos;s sidebar is one agent session: a title, where it lives, and what it is doing right now.
            Telar reads that from the agent&apos;s own traffic through its TLS proxy, not from hooks the agent may or
            may not fire.
          </p>
          <p>
            A new session starts as <em>New Pi session</em>. When it begins working, telar asks a model for a title
            from the first request, off the interactive path. Rename it inside the agent and the card follows.
          </p>
        </>
      }
    >
      <div className="mb-8 rounded-md border border-chrome-line bg-chrome-panel py-2">
        <div className="flex items-center gap-2 px-4 pt-2 pb-3 font-mono text-[13px]">
          <span className="text-chrome-subtext" aria-hidden="true">
            ❖
          </span>
          <span className="text-chrome-text">telar</span>
        </div>
        <AgentList inline />
      </div>

      <dl className="grid gap-x-8 gap-y-4 text-[15px] sm:grid-cols-2">
        {ORDER.map((key) => {
          const status = STATUSES[key];
          return (
            <div key={key}>
              <dt className={`font-mono text-[13px] ${status.tone}`}>
                <span aria-hidden="true">{status.glyph}</span> {status.label}
              </dt>
              <dd className="mt-1 text-subtext">{status.meaning}</dd>
            </div>
          );
        })}
      </dl>
    </Story>
  );
}
