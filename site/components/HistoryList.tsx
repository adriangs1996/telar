"use client";

import { useState } from "react";
import { HISTORY, SCOPES, inScope, type Scope } from "@/lib/history";

type Props = { autoFocus?: boolean; onEscape?: () => void };

// The history palette: one query box, the newest human-authored commands, and
// a scope that Tab narrows from everything down to this pane.
export default function HistoryList({ autoFocus = false, onEscape }: Props) {
  const [scope, setScope] = useState<Scope>("global");
  const [query, setQuery] = useState("");

  const visible = HISTORY.filter((row) => inScope(row, scope) && row.cmd.includes(query.trim()));

  const cycle = () => setScope((current) => SCOPES[(SCOPES.indexOf(current) + 1) % SCOPES.length]);

  return (
    <div className="overflow-hidden rounded-md border border-line bg-panel font-mono text-[13px] shadow-[0_12px_40px_rgba(0,0,0,.4)]">
      <label className="flex items-center gap-3 border-b border-line px-4 py-3">
        <span className="text-peach" aria-hidden="true">
          /
        </span>
        <input
          value={query}
          autoFocus={autoFocus}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Tab") {
              event.preventDefault();
              cycle();
            } else if (event.key === "Escape" && onEscape) {
              onEscape();
            }
          }}
          placeholder="search command history"
          aria-label="Search command history"
          spellCheck={false}
          className="w-full bg-transparent text-text placeholder:text-overlay-0 focus:outline-none"
        />
      </label>
      <ul className="min-h-[13.5rem] py-1">
        {visible.map((row) => (
          <li key={row.cmd} className="flex items-center justify-between gap-4 px-4 py-1.5 text-subtext">
            <span className="truncate">
              <span className="text-text">{row.cmd}</span>
              {row.agent ? <span className="ml-2 text-overlay-0">[agent]</span> : null}
            </span>
            <span className="shrink-0 text-[11px] text-overlay-1">
              {row.workspace} · pane {row.pane}
            </span>
          </li>
        ))}
        {visible.length === 0 ? <li className="px-4 py-3 text-overlay-1">Nothing here. Widen the scope with Tab.</li> : null}
      </ul>
      <div className="flex items-center justify-between border-t border-line px-4 py-2 text-[11px] text-overlay-1">
        <span>Tab cycles scope</span>
        <div className="flex gap-1">
          {SCOPES.map((item) => (
            <button
              key={item}
              type="button"
              onClick={() => setScope(item)}
              aria-pressed={scope === item}
              className={`rounded-sm px-1.5 py-0.5 transition-colors ${scope === item ? "bg-surface-1 text-peach" : "hover:text-text"}`}
            >
              {item}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
