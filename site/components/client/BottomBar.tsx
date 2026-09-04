"use client";

import { paneById, paneLocation, panesOfTab } from "@/lib/panes";
import { useClient, type Mode } from "./ClientProvider";

type Hint = [keys: string, verb: string];

const HINTS: Record<Mode, Hint[]> = {
  normal: [
    ["j/k", "panes"],
    ["h/l", "beside"],
    ["1-8", "jump"],
    ["z", "fullscreen"],
    ["/", "history"],
    ["?", "keys"],
  ],
  fullscreen: [
    ["z/Esc", "exit"],
    ["j/k", "panes"],
    ["1-8", "jump"],
  ],
  palette: [
    ["Tab", "scope"],
    ["Esc", "close"],
  ],
  keys: [["Esc", "close"]],
};

const LABELS: Record<Mode, string> = { normal: "NORMAL", fullscreen: "FULL", palette: "HISTORY", keys: "KEYS" };

export default function BottomBar() {
  const { mode, focused } = useClient();
  const raised = mode !== "normal";
  const siblings = panesOfTab(paneById(focused).tab);

  return (
    <footer className="attach hidden h-8 shrink-0 items-center gap-4 border-t border-chrome-line bg-chrome-bg px-3 font-mono text-[12px] lg:flex">
      <span
        className={`rounded-sm px-2 py-0.5 text-[11px] font-medium tracking-wide transition-colors ${
          raised ? "bg-chrome-accent text-chrome-bg" : "bg-chrome-surface text-chrome-text"
        }`}
      >
        {LABELS[mode]}
      </span>
      <ul className="flex items-center gap-4">
        {HINTS[mode].map(([keys, verb]) => (
          <li key={keys} className="text-chrome-subtext">
            <span className="font-medium text-chrome-text">{keys}</span> {verb}
          </li>
        ))}
      </ul>
      <span className="ml-auto flex items-center gap-3 text-chrome-subtext">
        {paneLocation(focused)}
        {siblings.length > 1 ? (
          <span className="flex items-center gap-1" aria-label={`${siblings.length} panes in this tab`}>
            {siblings.map((pane) => (
              <span
                key={pane.id}
                className={`h-1.5 w-1.5 rounded-full transition-colors ${pane.id === focused ? "bg-chrome-accent" : "bg-chrome-surface"}`}
              />
            ))}
          </span>
        ) : null}
      </span>
    </footer>
  );
}
