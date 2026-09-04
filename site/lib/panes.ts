// The page is laid out as one telar workspace. Every section is a pane with a
// number and the name of the process that would be running in it. Tabs group
// panes the way telar groups them on screen.

export type TabId = "overview" | "runtime" | "internals" | "setup";

export type PaneId = "hero" | "sidebar" | "server" | "paths" | "history" | "config" | "install" | "glossary";

export type Pane = { id: PaneId; number: number; process: string; tab: TabId };

export const WORKSPACE = "telar";

export const TABS: { id: TabId; label: string }[] = [
  { id: "overview", label: "overview" },
  { id: "runtime", label: "runtime" },
  { id: "internals", label: "internals" },
  { id: "setup", label: "setup" },
];

export const PANES: Pane[] = [
  { id: "hero", number: 1, process: "telar", tab: "overview" },
  { id: "sidebar", number: 2, process: "claude", tab: "overview" },
  { id: "server", number: 3, process: "telar server", tab: "runtime" },
  { id: "paths", number: 4, process: "pty", tab: "runtime" },
  { id: "history", number: 5, process: "sqlite", tab: "internals" },
  { id: "config", number: 6, process: "lua", tab: "internals" },
  { id: "install", number: 7, process: "zig", tab: "setup" },
  { id: "glossary", number: 8, process: "sh", tab: "setup" },
];

export function paneById(id: PaneId): Pane {
  return PANES.find((pane) => pane.id === id) ?? PANES[0];
}

export function paneByNumber(number: number): Pane | undefined {
  return PANES.find((pane) => pane.number === number);
}

export function firstPaneOfTab(tab: TabId): Pane {
  return PANES.find((pane) => pane.tab === tab) ?? PANES[0];
}

export function panesOfTab(tab: TabId): Pane[] {
  return PANES.filter((pane) => pane.tab === tab);
}

export function paneIndex(id: PaneId): number {
  return Math.max(0, PANES.findIndex((pane) => pane.id === id));
}

/// `telar › overview › pane 2`, the second row of every sidebar card.
export function paneLocation(id: PaneId): string {
  const pane = paneById(id);
  return `${WORKSPACE} › ${pane.tab} › pane ${pane.number}`;
}

export const DESKTOP = 1024;
