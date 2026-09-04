"use client";

import { paneById, panesOfTab, type PaneId } from "@/lib/panes";
import { useClient } from "./ClientProvider";
import Pane from "./Pane";

type Props = { panes: Record<PaneId, React.ReactNode> };

// The open tab's panes, side by side in a strip that slides to the focused
// one. Changing tab swaps the strip, and the new panes repaint in.
export default function Screens({ panes }: Props) {
  const { focused } = useClient();
  const tab = paneById(focused).tab;
  const siblings = panesOfTab(tab);
  const index = Math.max(0, siblings.findIndex((pane) => pane.id === focused));

  return (
    <div key={tab} className="strip" style={{ transform: `translateX(-${index * 100}%)` }}>
      {siblings.map((pane, position) => (
        <Pane key={pane.id} id={pane.id} position={position}>
          {panes[pane.id]}
        </Pane>
      ))}
    </div>
  );
}
