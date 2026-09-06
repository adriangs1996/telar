"use client";

import { useState } from "react";

type Props = { command: string; className?: string; prompt?: string };

// A shell line with a copy button. The button confirms for a moment and the
// text never wraps, so what the user copies is exactly what they read.
//
//   <CopyCommand command="zig build run" />
export default function CopyCommand({ command, className = "", prompt = "$" }: Props) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(command);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      setCopied(false);
    }
  };

  return (
    <div className={`flex items-stretch overflow-hidden rounded-md border border-line bg-panel font-mono text-[13.5px] ${className}`}>
      <pre className="min-w-0 flex-1 px-4 py-3 whitespace-pre-wrap break-all text-text">
        <code>
          <span className="text-peach">{prompt} </span>
          {command}
        </code>
      </pre>
      <button
        type="button"
        onClick={copy}
        aria-live="polite"
        className="shrink-0 border-l border-line px-4 text-[11px] tracking-[0.14em] text-subtext uppercase transition-colors hover:bg-surface hover:text-text"
      >
        {copied ? "copied" : "copy"}
      </button>
    </div>
  );
}
