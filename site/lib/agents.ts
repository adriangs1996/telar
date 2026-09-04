import type { PaneId } from "./panes";

export type Provider = "claude" | "codex" | "pi";

export type AgentStatus = "working" | "blocked" | "ready" | "done";

export type Agent = {
  id: string;
  title: string;
  provider: Provider;
  pane: PaneId;
  cwd: string;
  status: AgentStatus;
  generated?: boolean;
  rang?: boolean;
};

export type ToastKind = "done" | "blocked";

export type AgentEvent = {
  at: number;
  id: string;
  patch: Partial<Agent>;
  toast?: { kind: ToastKind; title: string; body: string };
};

// Mirrors src/frontend/ui/icons.zig and the sidebar's status table.
export const PROVIDERS: Record<Provider, { name: string; glyph: string; tone: string }> = {
  claude: { name: "Claude Code", glyph: "✳", tone: "text-chrome-accent" },
  codex: { name: "Codex", glyph: "◆", tone: "text-chrome-subtext" },
  pi: { name: "Pi", glyph: "π", tone: "text-chrome-teal" },
};

export const STATUSES: Record<AgentStatus, { label: string; glyph: string; tone: string; meaning: string }> = {
  working: {
    label: "working",
    glyph: "◐",
    tone: "text-chrome-accent",
    meaning: "The agent is producing output or waiting on the model.",
  },
  blocked: {
    label: "needs input",
    glyph: "!",
    tone: "text-chrome-yellow",
    meaning: "It asked you something and cannot continue. This state wins over every other.",
  },
  done: {
    label: "done",
    glyph: "✔",
    tone: "text-chrome-teal",
    meaning: "It finished a turn while you were looking elsewhere. It stays done until you look.",
  },
  ready: {
    label: "ready",
    glyph: "✓",
    tone: "text-chrome-green",
    meaning: "Finished and seen, or idle at its prompt.",
  },
};

export const SPINNER = ["◐", "◓", "◑", "◒"];

export const INITIAL_AGENTS: Agent[] = [
  { id: "capture", title: "Split proxy buffers", provider: "claude", pane: "sidebar", cwd: "~/sandbox/telar", status: "working" },
  { id: "bisect", title: "Fix the flaky test", provider: "codex", pane: "server", cwd: "~/sandbox/telar", status: "working" },
  { id: "pi", title: "New Pi session", provider: "pi", pane: "config", cwd: "~/sandbox/telar/docs", status: "working" },
  { id: "guide", title: "Write install docs", provider: "claude", pane: "install", cwd: "~/sandbox/telar/site", status: "ready" },
];

// What happens after a client attaches. Times are milliseconds since attach.
export const AGENT_SCRIPT: AgentEvent[] = [
  { at: 3200, id: "pi", patch: { title: "Explain the config", generated: true } },
  {
    at: 6500,
    id: "capture",
    patch: { status: "done", rang: true },
    toast: { kind: "done", title: "Claude Code finished a turn", body: "Split proxy buffers" },
  },
  {
    at: 13000,
    id: "bisect",
    patch: { status: "blocked" },
    toast: { kind: "blocked", title: "Codex needs input", body: "Fix the flaky test" },
  },
  {
    at: 21000,
    id: "pi",
    patch: { status: "done", rang: true },
    toast: { kind: "done", title: "Pi finished a turn", body: "Explain the config" },
  },
];
