"use client";

import type { PaneId } from "@/lib/panes";
import { useClient } from "./ClientProvider";

type Props = { to: PaneId; className?: string; children: React.ReactNode };

// An in-page link that navigates the way the client does: focus the pane and
// bring it under the top bar, instead of a raw anchor jump.
export default function PaneLink({ to, className, children }: Props) {
  const { focusPane } = useClient();

  return (
    <a
      href={`#${to}`}
      className={className}
      onClick={(event) => {
        event.preventDefault();
        focusPane(to);
      }}
    >
      {children}
    </a>
  );
}
