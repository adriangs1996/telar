"use client";

import { location } from "@/lib/agents";
import { useDemo } from "./DemoProvider";

const HINTS: [string, string][] = [
  ["j/k", "agents"],
  ["prefix+z", "fullscreen"],
  ["prefix+/", "history"],
  ["prefix+d", "detach"],
];

export default function BottomBar() {
  const { agents, focused, runtime } = useDemo();
  const agent = agents.find((item) => item.id === focused) ?? agents[0];

  return (
    <footer className="attach flex h-8 shrink-0 items-center gap-4 border-t border-chrome-line bg-chrome-bg px-3 font-mono text-[11.5px]" style={{ ["--delay" as string]: "120ms" }}>
      <span className="rounded-sm bg-chrome-surface px-2 py-0.5 text-[10.5px] font-medium tracking-wide text-chrome-text">NORMAL</span>
      <ul className="hidden items-center gap-4 sm:flex">
        {HINTS.map(([keys, verb]) => (
          <li key={keys} className="text-chrome-subtext">
            <span className="font-medium text-chrome-text">{keys}</span> {verb}
          </li>
        ))}
      </ul>
      <span className="ml-auto flex items-center gap-3 text-chrome-subtext">
        <span className="hidden tabular-nums text-chrome-overlay md:inline">pid {runtime.pid}</span>
        {location(agent)}
      </span>
    </footer>
  );
}
