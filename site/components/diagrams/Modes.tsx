"use client";

import { useEffect, useState } from "react";

// Two compositions of the same runtime. The blocks are the same four panes;
// only the client's arrangement changes when the mode flips.
const PANES = [
  { id: "a", label: "Split proxy buffers", project: "telar", attention: "done" },
  { id: "b", label: "Fix the flaky test", project: "telar", attention: "needs input" },
  { id: "c", label: "Explain the config", project: "telar", attention: "working" },
  { id: "d", label: "Webhook retries", project: "guruwalk", attention: "working" },
];

const TONE: Record<string, string> = { done: "text-teal", "needs input": "text-peach", working: "text-peach" };

export default function Modes() {
  const [agentMode, setAgentMode] = useState(false);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      return;
    }

    const timer = window.setInterval(() => setAgentMode((value) => !value), 3400);
    return () => window.clearInterval(timer);
  }, []);

  return (
    <div className="figure p-5 md:p-6">
      <div className="mb-4 flex items-center justify-between font-mono text-[11px]">
        <div className="flex gap-1 rounded-sm border border-line p-0.5">
          {(["multiplexer", "agent mode"] as const).map((label, index) => {
            const active = (index === 1) === agentMode;
            return (
              <button
                key={label}
                type="button"
                onClick={() => setAgentMode(index === 1)}
                aria-pressed={active}
                className={`rounded-[2px] px-2.5 py-1 transition-colors ${active ? "bg-surface-1 text-text" : "text-subtext hover:text-text"}`}
              >
                {label}
              </button>
            );
          })}
        </div>
        <span className="text-overlay-1">same panes · same runtime</span>
      </div>

      {agentMode ? (
        <div className="morph grid-cols-[9rem_1fr] text-[12px]">
          <div className="rounded-md border border-line bg-ink p-3 font-mono">
            <div className="text-[10.5px] tracking-[0.12em] text-overlay-1 uppercase">by attention</div>
            <ul className="mt-2 space-y-1 text-subtext">
              <li className="text-peach">! needs input · 1</li>
              <li className="text-teal">✔ done · 1</li>
              <li>◐ working · 2</li>
            </ul>
            <div className="mt-4 text-[10.5px] tracking-[0.12em] text-overlay-1 uppercase">by project</div>
            <ul className="mt-2 space-y-1 text-subtext">
              <li className="text-text">telar · 3</li>
              <li>guruwalk · 1</li>
            </ul>
          </div>
          <ul className="grid gap-1.5 font-mono">
            {[...PANES].sort((a, b) => ["needs input", "done", "working"].indexOf(a.attention) - ["needs input", "done", "working"].indexOf(b.attention)).map((pane) => (
              <li key={pane.id} className="flex items-center justify-between rounded-md border border-line bg-ink px-3 py-2">
                <span className="text-text">{pane.label}</span>
                <span className="flex gap-3 text-[11px]">
                  <span className="text-overlay-1">{pane.project}</span>
                  <span className={TONE[pane.attention]}>{pane.attention}</span>
                </span>
              </li>
            ))}
          </ul>
        </div>
      ) : (
        <div className="morph grid-cols-2 grid-rows-2 font-mono text-[12px]" style={{ height: "13.4rem" }}>
          {PANES.map((pane, index) => (
            <div key={pane.id} className={`relative rounded-md border bg-ink p-3 ${index === 1 ? "border-peach/60" : "border-line"}`}>
              <span className="absolute -top-2 left-3 bg-panel px-1 text-[10.5px] text-subtext">
                {index + 1} {pane.project === "telar" ? "claude" : "codex"}
              </span>
              <div className="text-text">{pane.label}</div>
              <div className={`mt-1 text-[11px] ${TONE[pane.attention]}`}>{pane.attention}</div>
            </div>
          ))}
        </div>
      )}

      <p className="mt-4 border-t border-line pt-4 font-mono text-[11.5px] leading-relaxed text-overlay-1">
        A thread is always a pane in a tab in a workspace. Agent mode indexes those panes by project and attention instead
        of inventing a second topology. Transcripts are read from the agent&apos;s own session files by offset and never
        copied.
      </p>
    </div>
  );
}
