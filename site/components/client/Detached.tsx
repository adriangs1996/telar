"use client";

import { useClient } from "./ClientProvider";

export default function Detached() {
  const { runtime, agents, attach } = useClient();
  const working = agents.filter((agent) => agent.status === "working").length;

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-ink px-6 font-mono">
      <div className="w-[min(30rem,100%)] text-[13.5px]">
        <div className="text-subtext">no client attached</div>
        <dl className="mt-5 grid grid-cols-[9rem_1fr] gap-y-1.5 border-t border-line pt-5 text-subtext">
          <dt>runtime</dt>
          <dd className="text-text">pid {runtime.pid}, still running</dd>
          <dt>agents</dt>
          <dd className="text-text">
            {agents.length}, {working} working
          </dd>
          <dt>pty bytes</dt>
          <dd className="tabular-nums text-mint">{runtime.bytes.toLocaleString("en-US")}</dd>
          <dt>agent turns</dt>
          <dd className="tabular-nums text-mint">{runtime.turns}</dd>
        </dl>
        <p className="mt-6 text-subtext">
          The screen is gone. Nothing that mattered lived in it.
        </p>
        <button
          type="button"
          onClick={attach}
          autoFocus
          className="mt-6 rounded-sm bg-peach px-4 py-2 text-[13px] font-medium text-ink transition-colors hover:bg-mauve"
        >
          Attach a client
        </button>
      </div>
    </div>
  );
}
