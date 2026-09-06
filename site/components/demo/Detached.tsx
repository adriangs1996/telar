"use client";

import { useDemo } from "./DemoProvider";

// What is left when the client is gone: nothing on screen, everything in the
// runtime. The counters are the same ones the window was showing.
export default function Detached() {
  const { runtime, agents, attach } = useDemo();
  const working = agents.filter((agent) => agent.status === "working").length;
  const blocked = agents.filter((agent) => agent.status === "blocked").length;

  return (
    <div className="flex h-full items-center justify-center bg-ink px-6 font-mono">
      <div className="w-[min(30rem,100%)] text-[13.5px]">
        <div className="flex items-center gap-2 text-subtext">
          <span className="heartbeat inline-block h-2 w-2 rounded-full bg-mint" aria-hidden="true" />
          no client attached · runtime up
        </div>
        <dl className="mt-5 grid grid-cols-[9rem_1fr] gap-y-1.5 border-t border-line pt-5 text-subtext">
          <dt>runtime</dt>
          <dd className="text-text">pid {runtime.pid}, still running</dd>
          <dt>agents</dt>
          <dd className="text-text">
            {agents.length} open · {working} working{blocked ? ` · ${blocked} waiting for you` : ""}
          </dd>
          <dt>pty bytes</dt>
          <dd className="tabular-nums text-mint">{runtime.bytes.toLocaleString("en-US")}</dd>
          <dt>agent turns</dt>
          <dd className="tabular-nums text-mint">{runtime.turns}</dd>
        </dl>
        <p className="mt-6 text-subtext">The screen is gone. Nothing that mattered lived in it.</p>
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
