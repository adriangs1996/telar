"use client";

import { useRef } from "react";
import { PANES } from "@/lib/panes";
import BottomBar from "./BottomBar";
import { useClient } from "./ClientProvider";
import Detached from "./Detached";
import KeysOverlay from "./KeysOverlay";
import Palette from "./Palette";
import Toasts from "./Toasts";
import TopBar from "./TopBar";

// One terminal window on a desk. The page scrolls one step per pane while
// the window stays pinned and swaps what it shows. Sideways gestures move
// between the panes of the open tab. Keyed by attach epoch so a reattach
// redraws everything from scratch.
export default function Chrome({ children }: { children: React.ReactNode }) {
  const { attached, epoch, overlay, fullscreen, registerTrack, navigate } = useClient();
  const sideways = useRef({ amount: 0, at: 0 });
  const touch = useRef<{ x: number; y: number } | null>(null);

  if (!attached) {
    return <Detached />;
  }

  const onWheel = (event: React.WheelEvent) => {
    if (Math.abs(event.deltaX) < Math.abs(event.deltaY) * 1.5) {
      return;
    }

    const now = performance.now();
    if (now - sideways.current.at < 600) {
      return;
    }

    sideways.current.amount += event.deltaX;
    if (Math.abs(sideways.current.amount) > 80) {
      navigate(sideways.current.amount > 0 ? "right" : "left");
      sideways.current = { amount: 0, at: now };
    }
  };

  const onTouchStart = (event: React.TouchEvent) => {
    touch.current = { x: event.touches[0].clientX, y: event.touches[0].clientY };
  };

  const onTouchEnd = (event: React.TouchEvent) => {
    const from = touch.current;
    touch.current = null;
    if (!from) {
      return;
    }

    const dx = event.changedTouches[0].clientX - from.x;
    const dy = event.changedTouches[0].clientY - from.y;
    if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.5) {
      navigate(dx < 0 ? "right" : "left");
    }
  };

  return (
    <div key={epoch} data-fullscreen={fullscreen} className="client">
      <div className="track" ref={registerTrack}>
        <div className="stage">
          <div className="window">
            <TopBar />
            <div className="window-body">
              <main className="window-main" onWheel={onWheel} onTouchStart={onTouchStart} onTouchEnd={onTouchEnd}>
                {children}
                <Toasts />
              </main>
            </div>
            <BottomBar />
          </div>
        </div>
        {PANES.slice(1).map((pane) => (
          <div key={pane.id} className="step" aria-hidden="true" />
        ))}
      </div>
      {overlay === "palette" ? <Palette /> : null}
      {overlay === "keys" ? <KeysOverlay /> : null}
    </div>
  );
}
