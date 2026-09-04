"use client";

import { useClient } from "./ClientProvider";

export default function Toasts() {
  const { toasts } = useClient();

  return (
    <div className="pointer-events-none absolute top-4 right-4 z-40 flex w-[min(22rem,calc(100%-2rem))] flex-col gap-2" aria-live="polite">
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className={`toast rounded-md border border-chrome-line bg-chrome-panel px-4 py-3 font-mono text-[12.5px] shadow-[0_8px_30px_rgba(0,0,0,.45)] ${
            toast.kind === "blocked" ? "border-l-chrome-yellow" : "border-l-chrome-teal"
          } border-l-2`}
        >
          <div className="flex items-center gap-2 text-chrome-text">
            <span aria-hidden="true" className={toast.kind === "blocked" ? "text-chrome-yellow" : "text-chrome-teal"}>
              {toast.kind === "blocked" ? "!" : "♪"}
            </span>
            {toast.title}
          </div>
          <div className="mt-0.5 truncate text-chrome-subtext">{toast.body}</div>
        </div>
      ))}
    </div>
  );
}
