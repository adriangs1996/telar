"use client";

import Reveal from "@/components/Reveal";
import { useDemo } from "@/components/demo/DemoProvider";
import Window from "@/components/demo/Window";
import { STATUSES, type AgentStatus } from "@/lib/agents";
import { THEMES } from "@/lib/themes";

const ORDER: AgentStatus[] = ["working", "blocked", "done", "ready"];

export default function Demo() {
  const { attached, detach, theme, setTheme } = useDemo();

  return (
    <section id="demo" className="rails hairline px-5 py-16 md:px-8 md:py-24">
      <Reveal className="flex flex-wrap items-end justify-between gap-6">
        <div style={{ ["--i" as string]: 0 }}>
          <p className="eyebrow">one client, drawn on this page</p>
          <h2 className="title mt-5 max-w-[22ch] text-[clamp(1.9rem,3.6vw,3rem)]">
            The sidebar knows what every agent is doing. <em>Without asking it.</em>
          </h2>
        </div>
        <p className="measure text-[15.5px] text-subtext" style={{ ["--i" as string]: 1 }}>
          Four agents in one workspace. Watch the sidebar: in a few seconds Pi gets a title, finishes and rings; Codex
          stops to ask you something. Click an agent, or press <kbd>j</kbd> and <kbd>k</kbd> with the window focused.
        </p>
      </Reveal>

      <Reveal className="mt-10">
        <div style={{ ["--i" as string]: 0 }}>
          <Window />
        </div>
      </Reveal>

      <div className="mt-6 flex flex-wrap items-center gap-x-8 gap-y-4">
        <button
          type="button"
          onClick={detach}
          disabled={!attached}
          className="rounded-sm border border-overlay-0 px-4 py-2 font-mono text-[13px] text-text transition-colors hover:border-peach hover:text-peach disabled:cursor-not-allowed disabled:opacity-40"
        >
          Kill this client
        </button>
        <span className="text-[14.5px] text-subtext">
          The window is the client. The agents and the counters live in the runtime, and will not notice.
        </span>

        <div className="ml-auto flex items-center gap-2" role="group" aria-label="Chrome theme">
          <span className="mr-1 font-mono text-[11px] tracking-[0.12em] text-overlay-1 uppercase">theme</span>
          {THEMES.map((item) => {
            const active = item.id === theme;
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => setTheme(item.id)}
                aria-pressed={active}
                title={item.label}
                className={`flex h-7 w-12 overflow-hidden rounded-sm border transition-colors ${active ? "border-peach" : "border-line hover:border-overlay-0"}`}
              >
                {item.swatch.map((color, index) => (
                  <span key={index} className="flex-1" style={{ background: color }} />
                ))}
              </button>
            );
          })}
        </div>
      </div>

      <Reveal as="div" className="mt-14 grid gap-x-10 gap-y-6 sm:grid-cols-2 lg:grid-cols-4">
        {ORDER.map((key, index) => {
          const status = STATUSES[key];
          return (
            <div key={key} style={{ ["--i" as string]: index }}>
              <dt className={`font-mono text-[13px] ${status.tone}`}>
                <span aria-hidden="true">{status.glyph}</span> {status.label}
              </dt>
              <dd className="mt-1.5 text-[14.5px] leading-snug text-subtext">{status.meaning}</dd>
            </div>
          );
        })}
      </Reveal>
    </section>
  );
}
