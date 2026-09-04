"use client";

import { paneById, type PaneId } from "@/lib/panes";
import { useClient } from "./ClientProvider";

type Props = { id: PaneId; position: number; children: React.ReactNode };

// One pane of the open tab. The border carries the pane number and process
// name; focus draws the border again in the accent color.
export default function Pane({ id, position, children }: Props) {
  const { focused, fullscreen, focusPane, toggleFullscreen } = useClient();
  const pane = paneById(id);
  const isFocused = focused === id;

  return (
    <div className="pane-slot">
      <section
        id={id}
        data-focused={isFocused}
        inert={!isFocused}
        aria-label={`Pane ${pane.number}, ${pane.process}`}
        className="pane"
        style={{ ["--pane-index" as string]: position }}
        onPointerDown={() => {
          if (!isFocused) {
            focusPane(id);
          }
        }}
      >
        <svg className="pane-ring" aria-hidden="true">
          <rect pathLength={1} />
        </svg>
        <span className="pane-title">
          {pane.number} {pane.process}
        </span>
        <button
          type="button"
          className="pane-tools"
          aria-label={fullscreen ? "Leave fullscreen" : "Fullscreen the window"}
          onPointerDown={(event) => event.stopPropagation()}
          onClick={toggleFullscreen}
        >
          {fullscreen ? "×" : "⛶"}
        </button>
        <div className="pane-body">{children}</div>
      </section>
    </div>
  );
}
