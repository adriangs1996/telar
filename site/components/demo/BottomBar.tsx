"use client";

import { TABS } from "@/lib/agents";
import { useDemo } from "./DemoProvider";

// telar's bottom bar: host vitals on the left, the open workspace's tabs on
// the right with the active one filled in the accent color.
export default function BottomBar() {
  const { agents, focused, focusTab } = useDemo();
  const activeTab = agents.find((agent) => agent.id === focused)?.tab ?? TABS[0];

  return (
    <footer className="attach flex h-8 shrink-0 items-center border-t border-chrome-line bg-chrome-bg px-3 font-mono text-[11.5px] text-chrome-accent" style={{ ["--delay" as string]: "120ms" }}>
      <ul className="hidden items-center gap-2 sm:flex" aria-label="Host">
        <li>◷ 06/09 23:52</li>
        <li className="text-chrome-overlay">|</li>
        <li>▮ 100%</li>
        <li className="text-chrome-overlay">|</li>
        <li>◎ 35%</li>
        <li className="text-chrome-overlay">|</li>
        <li>▤ 10.8G</li>
      </ul>
      <nav aria-label="Tabs" className="ml-auto flex items-center gap-1">
        {TABS.map((tab, index) => {
          const active = tab === activeTab;
          return (
            <button
              key={tab}
              type="button"
              onClick={() => focusTab(tab)}
              aria-current={active ? "page" : undefined}
              className={`rounded-[3px] px-2 py-0.5 ${active ? "bg-chrome-accent font-medium text-chrome-bg" : "bg-chrome-panel text-chrome-subtext hover:text-chrome-text"}`}
            >
              {index + 1}:{tab}
            </button>
          );
        })}
      </nav>
    </footer>
  );
}
