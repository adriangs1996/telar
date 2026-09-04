"use client";

import { useClient } from "./ClientProvider";

const KEYS: [string, string][] = [
  ["j / k", "next or previous pane"],
  ["h / l", "the pane beside, inside the tab"],
  ["1 – 8", "jump to a pane"],
  ["z, Enter", "fullscreen the window"],
  ["/", "search command history"],
  ["?", "this list"],
  ["Esc", "close, or leave fullscreen"],
];

export default function KeysOverlay() {
  const { closeOverlay } = useClient();

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-chrome-bg/70 px-4" onPointerDown={closeOverlay}>
      <div
        role="dialog"
        aria-label="Keys"
        className="modal-in w-[min(26rem,100%)] rounded-md border border-chrome-line bg-chrome-panel p-5 font-mono text-[13px]"
        onPointerDown={(event) => event.stopPropagation()}
      >
        <div className="mb-3 text-chrome-text">Keys on this page</div>
        <dl className="grid grid-cols-[6.5rem_1fr] gap-y-2">
          {KEYS.map(([keys, verb]) => (
            <div key={keys} className="contents">
              <dt className="text-chrome-accent">{keys}</dt>
              <dd className="text-chrome-subtext">{verb}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-4 text-[12px] text-chrome-overlay">In telar these are your own bindings. Here they are the defaults.</p>
      </div>
    </div>
  );
}
