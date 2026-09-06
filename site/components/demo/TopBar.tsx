"use client";

import { TABS, WORKSPACE } from "@/lib/agents";
import { useDemo } from "./DemoProvider";

export default function TopBar() {
  const { agents, focused, focusAgent } = useDemo();
  const activeTab = agents.find((agent) => agent.id === focused)?.tab ?? TABS[0];

  return (
    <header className="attach flex h-10 shrink-0 items-center border-b border-chrome-line bg-chrome-bg font-mono text-[12px] sm:text-[13px]">
      <div className="flex h-full shrink-0 items-center gap-2 border-r border-chrome-line px-4">
        <span className="text-chrome-subtext" aria-hidden="true">
          ❖
        </span>
        <span className="text-chrome-text">{WORKSPACE}</span>
      </div>

      <nav aria-label="Tabs" className="flex h-full min-w-0 flex-1 items-stretch overflow-x-auto pl-1">
        {TABS.map((tab) => {
          const active = tab === activeTab;
          const first = agents.find((agent) => agent.tab === tab);
          return (
            <button
              key={tab}
              type="button"
              onClick={() => first && focusAgent(first.id)}
              aria-current={active ? "page" : undefined}
              className={`relative flex shrink-0 items-center gap-1.5 px-3 ${active ? "text-chrome-text" : "text-chrome-subtext hover:text-chrome-text"}`}
            >
              <span className={`text-[10px] ${active ? "text-chrome-accent opacity-100" : "opacity-0"}`}>◆</span>
              {tab}
              <span
                className={`absolute inset-x-3 bottom-0 h-px bg-chrome-accent transition-transform duration-300 ${active ? "scale-x-100" : "scale-x-0"}`}
              />
            </button>
          );
        })}
      </nav>

      <div className="flex h-full shrink-0 items-center gap-4 pr-4 pl-2 text-chrome-subtext">
        <span className="flex items-center gap-1 text-chrome-accent" title="TLS interception active on the model-API allowlist">
          <span aria-hidden="true">⛨</span> tls
        </span>
        <span className="hidden items-center gap-1 sm:flex" title="Battery">
          <span aria-hidden="true">▮▮▮▯</span>
        </span>
      </div>
    </header>
  );
}
