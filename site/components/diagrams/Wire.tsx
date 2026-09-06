"use client";

import { useEffect, useState } from "react";

// One model exchange as ProxyTLS sees it, and the sidebar state it yields.
// The steps light up in order and loop; nothing here comes from a hook.
const STEPS: { at: number; line: string; note: string; status: "ready" | "working" | "blocked" }[] = [
  { at: 0, line: "CONNECT api.anthropic.com:443", note: "pane credential checked · host on the allowlist", status: "ready" },
  { at: 1, line: "TLS · ALPN h2 mirrored from the origin", note: "origin validated first, then the child", status: "ready" },
  { at: 2, line: "POST /v1/messages", note: "request head observed · working", status: "working" },
  { at: 3, line: "tool_use: Edit  src/backend/proxy/capture/buffers.zig", note: "provider event · still working", status: "working" },
  { at: 4, line: "POST /v1/messages", note: "the tool result goes back up", status: "working" },
  { at: 5, line: "stop_reason: end_turn", note: "provider turn completion · no exchange left open", status: "ready" },
  { at: 6, line: "◐ → ✓  ♪", note: "working → ready; the runtime emits one sound event", status: "ready" },
];

const TONE = { ready: "text-mint", working: "text-peach", blocked: "text-peach" };

export default function Wire() {
  const [step, setStep] = useState(0);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setStep(STEPS.length - 1);
      return;
    }

    const timer = window.setInterval(() => setStep((value) => (value + 1) % (STEPS.length + 2)), 1400);
    return () => window.clearInterval(timer);
  }, []);

  const current = Math.min(step, STEPS.length - 1);
  const status = STEPS[current].status;

  return (
    <div className="figure grid xl:grid-cols-[minmax(0,1fr)_13.5rem]">
      <ol className="min-w-0 p-5 font-mono text-[12px] md:p-7">
        {STEPS.map((item, index) => (
          <li key={index} className="wire-step flex gap-4 py-1.5" data-on={index <= step}>
            <span className="mt-1.5 flex w-3 shrink-0 justify-center">
              <span className="wire-dot" />
            </span>
            <div className="min-w-0">
              <div className="truncate text-text">{item.line}</div>
              <div className="truncate text-[11px] text-overlay-1">{item.note}</div>
            </div>
          </li>
        ))}
      </ol>

      <aside className="flex flex-col justify-between border-t border-line bg-ink p-5 xl:border-t-0 xl:border-l">
        <div>
          <div className="font-mono text-[10.5px] tracking-[0.14em] text-overlay-1 uppercase">sidebar card</div>
          <div className="mt-3 rounded-md border border-line bg-panel p-3 font-mono text-[12px]">
            <div className="flex items-baseline justify-between gap-2">
              <span className="text-text">Split proxy buffers</span>
              <span className={`shrink-0 ${TONE[status]}`}>{status === "working" ? "◐ working" : "✓ ready"}</span>
            </div>
            <div className="mt-1 text-subtext">telar › proxy › pane 1</div>
            <div className="text-overlay-0">Claude Code · ~/sandbox/telar</div>
          </div>
        </div>
        <dl className="mt-6 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 font-mono text-[11px] text-subtext sm:grid-cols-[auto_1fr_auto_1fr] xl:grid-cols-[auto_1fr]">
          <dt>credential</dt>
            <dd className="text-right text-text">128-bit, per pane</dd>
          <dt>listener</dt>
            <dd className="text-right text-text">loopback only</dd>
          <dt>other hosts</dt>
            <dd className="text-right text-text">passed through</dd>
          <dt>OS trust store</dt>
            <dd className="text-right text-text">untouched</dd>
        </dl>
      </aside>
    </div>
  );
}
