"use client";

import { useDemo } from "@/components/demo/DemoProvider";

const RUNTIME_OWNS = ["child processes and their ptys", "one vt.Terminal per pane", "what each agent is doing", "command history", "the proxy and its credentials"];
const CLIENT_OWNS = ["layout and splits", "the focused pane", "hover, scroll, selection", "which modal is open", "this window"];

// The two processes, with the live counters from the demo. Killing the
// client above greys this side out; the runtime column keeps counting.
export default function Split() {
  const { runtime, agents, attached, attach } = useDemo();
  const working = agents.filter((agent) => agent.status === "working").length;

  return (
    <div className="figure grid gap-px bg-line font-mono text-[12.5px] sm:grid-cols-2">
      <div className="bg-panel p-5 md:p-6">
        <div className="mb-4 flex items-baseline justify-between">
          <span className="flex items-center gap-2 text-text">
            <span className="heartbeat inline-block h-1.5 w-1.5 rounded-full bg-mint" aria-hidden="true" />
            runtime
          </span>
          <span className="text-overlay-1">pid {runtime.pid}</span>
        </div>
        <ul className="space-y-1.5 text-subtext">
          {RUNTIME_OWNS.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
        <dl className="mt-5 grid grid-cols-[1fr_auto] gap-y-1 border-t border-line pt-3 text-[12px]">
          <dt className="text-overlay-1">pty bytes</dt>
          <dd className="tabular-nums text-mint">{runtime.bytes.toLocaleString("en-US")}</dd>
          <dt className="text-overlay-1">agent turns</dt>
          <dd className="tabular-nums text-mint">{runtime.turns}</dd>
          <dt className="text-overlay-1">agents working</dt>
          <dd className="tabular-nums text-text">{working}</dd>
        </dl>
      </div>

      <div className="client-ghost bg-panel p-5 md:p-6" data-dead={!attached}>
        <div className="mb-4 flex items-baseline justify-between">
          <span className="text-text">client</span>
          <span className="text-overlay-1">{attached ? "attached" : "gone"}</span>
        </div>
        <ul className="space-y-1.5 text-subtext">
          {CLIENT_OWNS.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
        <div className="mt-5 border-t border-line pt-3 text-[12px] text-overlay-1">
          {attached ? (
            "Disposable. All of it can be rebuilt from the runtime."
          ) : (
            <button type="button" onClick={attach} className="text-peach underline decoration-line underline-offset-4 hover:text-mauve">
              Attach a client
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
