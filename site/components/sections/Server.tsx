"use client";

import { useClient } from "@/components/client/ClientProvider";
import Story from "./Story";

const runtimeOwns = ["child processes", "PTYs", "terminal state per pane", "what each agent is doing", "history"];
const clientOwns = ["layout", "focused pane", "hover", "scroll position", "selection", "open modal"];

export default function Server() {
  const { runtime, agents, detach } = useClient();

  return (
    <Story
      title="Two processes. One of them survives you."
      intro={
        <>
          <p>
            The runtime owns everything that has to outlive the screen. The client owns only what makes sense while
            somebody is looking, and all of it is disposable.
          </p>
          <p>
            The test for where a piece of state belongs is short. Kill the client. If the session is ruined, it was
            in the wrong process.
          </p>
        </>
      }
    >
      <div className="grid gap-px overflow-hidden rounded-md border border-line bg-line font-mono text-[13px] sm:grid-cols-2">
        <div className="bg-panel p-5">
          <div className="mb-3 flex items-baseline justify-between">
            <span className="text-text">runtime</span>
            <span className="text-overlay-1">pid {runtime.pid}</span>
          </div>
          <ul className="space-y-1 text-subtext">
            {runtimeOwns.map((item) => (
              <li key={item}>{item}</li>
            ))}
          </ul>
          <dl className="mt-5 grid grid-cols-[1fr_auto] gap-y-1 border-t border-line pt-3 text-[12px]">
            <dt className="text-overlay-1">pty bytes</dt>
            <dd className="tabular-nums text-mint">{runtime.bytes.toLocaleString("en-US")}</dd>
            <dt className="text-overlay-1">agent turns</dt>
            <dd className="tabular-nums text-mint">{runtime.turns}</dd>
            <dt className="text-overlay-1">agents</dt>
            <dd className="tabular-nums text-text">{agents.length}</dd>
          </dl>
        </div>
        <div className="bg-panel p-5">
          <div className="mb-3 flex items-baseline justify-between">
            <span className="text-text">client</span>
            <span className="text-overlay-1">this page</span>
          </div>
          <ul className="space-y-1 text-subtext">
            {clientOwns.map((item) => (
              <li key={item}>{item}</li>
            ))}
          </ul>
        </div>
      </div>

      <div className="mt-5 flex flex-wrap items-center gap-4 text-[14px]">
        <button
          type="button"
          onClick={detach}
          className="rounded-sm border border-overlay-0 px-4 py-2 font-mono text-[13px] text-text transition-colors hover:border-peach hover:text-peach"
        >
          Kill this client
        </button>
        <span className="text-overlay-1">This whole page is the client. The counters will not notice.</span>
      </div>
    </Story>
  );
}
