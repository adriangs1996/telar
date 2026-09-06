"use client";

import { useDemo } from "./DemoProvider";

export default function Toasts() {
  const { toasts } = useDemo();

  return (
    <div className="pointer-events-none absolute top-6 right-6 z-20 flex w-[min(20rem,calc(100%-3rem))] flex-col gap-2" aria-live="polite">
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className={`toast rounded-md border border-chrome-line border-l-2 bg-chrome-panel px-4 py-3 font-mono text-[12px] shadow-[0_8px_30px_rgba(0,0,0,.45)] ${
            toast.kind === "blocked" ? "border-l-chrome-yellow" : "border-l-chrome-teal"
          }`}
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
