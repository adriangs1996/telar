"use client";

import { useDemo } from "./DemoProvider";
import BottomBar from "./BottomBar";
import Detached from "./Detached";
import Sidebar from "./Sidebar";
import Terminal from "./Terminal";
import Toasts from "./Toasts";
import TopBar from "./TopBar";

// One telar client, drawn in HTML. Keyed by attach epoch so a reattach
// repaints everything from scratch, the way a real client does.
export default function Window() {
  const { attached, epoch, step } = useDemo();

  if (!attached) {
    return (
      <div className="window">
        <Detached />
      </div>
    );
  }

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "j" || event.key === "ArrowDown") {
      event.preventDefault();
      step(1);
    } else if (event.key === "k" || event.key === "ArrowUp") {
      event.preventDefault();
      step(-1);
    }
  };

  return (
    <div key={epoch} className="window" tabIndex={0} onKeyDown={onKeyDown} aria-label="A telar client">
      <TopBar />
      <div className="relative flex min-h-0 flex-1">
        <Sidebar />
        <main className="relative min-w-0 flex-1 px-3 pt-4 pb-3">
          <Terminal />
          <Toasts />
        </main>
      </div>
      <BottomBar />
    </div>
  );
}
