"use client";

import HistoryList from "@/components/HistoryList";
import { useClient } from "./ClientProvider";

export default function Palette() {
  const { closeOverlay } = useClient();

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center bg-chrome-bg/70 px-4 pt-[16vh]" onPointerDown={closeOverlay}>
      <div
        role="dialog"
        aria-label="Command history"
        className="modal-in w-[min(40rem,100%)]"
        onPointerDown={(event) => event.stopPropagation()}
      >
        <HistoryList autoFocus onEscape={closeOverlay} />
      </div>
    </div>
  );
}
