"use client";

import { PROVIDERS, USAGE, WORKSPACES } from "@/lib/agents";

// telar's top bar: the mark, the workspaces on this host with the open one
// underlined, and on the right the per-provider quota badges the proxy makes
// possible, then the TLS interception shield.
export default function TopBar() {
  return (
    <header className="attach flex h-9 shrink-0 items-center border-b border-chrome-line bg-chrome-bg px-3 font-mono text-[12px]">
      <img src="/brand/telar-mark-small.svg" alt="" width={14} height={14} className="mr-3 opacity-70" />
      <nav aria-label="Workspaces" className="flex h-full min-w-0 flex-1 items-stretch gap-4">
        {WORKSPACES.map((workspace, index) => {
          const active = index === 0;
          return (
            <span key={workspace} className={`relative flex items-center ${active ? "text-chrome-text" : "text-chrome-overlay"}`}>
              {workspace}
              {active ? <span className="absolute inset-x-0 bottom-0 h-px bg-chrome-accent" /> : null}
            </span>
          );
        })}
      </nav>

      <div className="flex h-full shrink-0 items-center gap-4 pl-2 text-[11.5px]">
        {USAGE.map((usage) => (
          <span key={usage.provider} className="hidden items-center gap-1.5 text-chrome-green sm:flex" title={`${PROVIDERS[usage.provider].name} quota`}>
            <img src={PROVIDERS[usage.provider].mark} alt="" width={12} height={12} className="rounded-[3px]" />
            {usage.label} <span className="text-chrome-green/90">{usage.text}</span>
          </span>
        ))}
        <span className="text-chrome-accent" title="TLS interception active on the model-API allowlist" aria-label="TLS interception active">
          ⛨
        </span>
      </div>
    </header>
  );
}
