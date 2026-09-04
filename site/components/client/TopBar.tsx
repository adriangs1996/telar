"use client";

import { TABS, WORKSPACE, firstPaneOfTab, paneById } from "@/lib/panes";
import { useClient } from "./ClientProvider";

export default function TopBar() {
  const { focused, focusPane } = useClient();
  const activeTab = paneById(focused).tab;

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
          const active = tab.id === activeTab;
          return (
            <button
              key={tab.id}
              type="button"
              onClick={() => focusPane(firstPaneOfTab(tab.id).id)}
              aria-current={active ? "page" : undefined}
              className={`relative flex shrink-0 items-center gap-1.5 px-2.5 transition-colors sm:px-3 ${
                active ? "text-chrome-text" : "text-chrome-subtext hover:text-chrome-text"
              }`}
            >
              <span className={`text-[10px] transition-opacity ${active ? "text-chrome-accent opacity-100" : "opacity-0"}`}>◆</span>
              {tab.label}
              <span
                className={`absolute inset-x-3 bottom-0 h-px bg-chrome-accent transition-transform duration-300 ${
                  active ? "scale-x-100" : "scale-x-0"
                }`}
              />
            </button>
          );
        })}
      </nav>

      <div className="flex h-full shrink-0 items-center gap-4 pr-3 pl-2 text-chrome-subtext sm:pr-4">
        <span className="hidden items-center gap-1 text-chrome-accent sm:flex" title="TLS interception active">
          <span aria-hidden="true">⛨</span> tls
        </span>
        <a href="https://github.com/adriangs1996/telar/tree/main/docs" className="hidden transition-colors hover:text-chrome-text sm:block">
          docs
        </a>
        <a href="https://github.com/adriangs1996/telar" className="transition-colors hover:text-chrome-text">
          github
        </a>
      </div>
    </header>
  );
}
