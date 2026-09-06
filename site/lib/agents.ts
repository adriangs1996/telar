// The demo window's data: one workspace, its tabs, the agents in its panes and
// what each pane shows. Everything is scripted; the shapes mirror the sidebar
// contract in docs/sidebar.md (title, workspace › tab › pane, provider · cwd).

export type Provider = "claude" | "codex" | "pi";

export type AgentStatus = "working" | "blocked" | "ready" | "done";

export type Line = { at: number; text: string; tone?: "dim" | "ok" | "warn" | "accent" | "prompt" };

export type Agent = {
  id: string;
  title: string;
  provider: Provider;
  tab: string;
  pane: number;
  cwd: string;
  status: AgentStatus;
  generated?: boolean;
  rang?: boolean;
  lines: Line[];
};

export type ToastKind = "done" | "blocked";

export type AgentEvent = {
  at: number;
  id: string;
  patch: Partial<Agent>;
  toast?: { kind: ToastKind; title: string; body: string };
};

export const WORKSPACE = "telar";

export const TABS = ["proxy", "tests", "docs"];

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
    meaning: "A model exchange or a tool call is in flight. Derived from the agent's own traffic.",
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
    meaning: "At its prompt with no exchange open. Finished and seen, or never started.",
  },
};

export const SPINNER = ["◐", "◓", "◑", "◒"];

const claudeLines: Line[] = [
  { at: 0, text: "~/sandbox/telar  main", tone: "accent" },
  { at: 300, text: "❯ split the proxy capture buffers per direction", tone: "prompt" },
  { at: 1400, text: "● Read src/backend/proxy/capture/root.zig", tone: "dim" },
  { at: 2300, text: "● Read src/backend/proxy/capture/buffers.zig", tone: "dim" },
  { at: 3600, text: "  One ring serves both directions today. Response bodies starve request heads under load." },
  { at: 5200, text: "● Edit src/backend/proxy/capture/buffers.zig", tone: "dim" },
  { at: 6400, text: "  +42 −11  DirectionalRing{ request, response } behind the same quota" },
  { at: 7900, text: "● Bash zig build test -Dtest-filter=capture", tone: "dim" },
  { at: 9800, text: "  All 38 tests passed.", tone: "ok" },
  { at: 11200, text: "  Done. Both rings share one quota; the head of a request can no longer wait on a body." },
];

const codexLines: Line[] = [
  { at: 0, text: "~/sandbox/telar  perf/echo", tone: "accent" },
  { at: 300, text: "› find why pane_lifecycle flakes on Linux", tone: "prompt" },
  { at: 1500, text: "  running zig build test 20× with -Dtest-filter=pane_lifecycle", tone: "dim" },
  { at: 3200, text: "  17 passed · 3 failed · error.WouldBlock in waitForExit", tone: "warn" },
  { at: 4800, text: "  The reaper polls before SIGCHLD lands. The test asserts on the first poll." },
  { at: 6500, text: "  Two fixes are possible:" },
  { at: 6900, text: "    1. wait on the pidfd in the test" },
  { at: 7300, text: "    2. make waitForExit retry with a bounded deadline" },
  { at: 8600, text: "? Option 2 changes production behavior. Which one do you want?", tone: "warn" },
];

const piLines: Line[] = [
  { at: 0, text: "~/sandbox/telar/docs  main", tone: "accent" },
  { at: 300, text: "π explain runtime.proxy in config.lua", tone: "prompt" },
  { at: 1600, text: "  reading docs/proxy-tls.md", tone: "dim" },
  { at: 3000, text: "  `enabled` starts the loopback listener on ports 45100–45227." },
  { at: 4200, text: "  `intercept_hosts` replaces the default allowlist of model APIs." },
  { at: 5400, text: "  `capture.enabled` turns on bounded exchange buffers for plugins." },
  { at: 6800, text: "  Everything else is passed through byte for byte.", tone: "ok" },
];

const shellLines: Line[] = [
  { at: 0, text: "~/sandbox/telar/site  main", tone: "accent" },
  { at: 300, text: "$ npm run build", tone: "prompt" },
  { at: 1800, text: "  ▲ Next.js 16.3.4", tone: "dim" },
  { at: 2600, text: "  Creating an optimized production build ...", tone: "dim" },
  { at: 5200, text: "  ✓ Compiled successfully", tone: "ok" },
  { at: 6000, text: "  ✓ Generating static pages (5/5)", tone: "ok" },
  { at: 6800, text: "$ ", tone: "prompt" },
];

export const INITIAL_AGENTS: Agent[] = [
  { id: "capture", title: "Split proxy buffers", provider: "claude", tab: "proxy", pane: 1, cwd: "~/sandbox/telar", status: "working", lines: claudeLines },
  { id: "bisect", title: "Fix the flaky test", provider: "codex", tab: "tests", pane: 1, cwd: "~/sandbox/telar", status: "working", lines: codexLines },
  { id: "pi", title: "New Pi session", provider: "pi", tab: "docs", pane: 1, cwd: "~/sandbox/telar/docs", status: "working", lines: piLines },
  { id: "guide", title: "Build the site", provider: "claude", tab: "docs", pane: 2, cwd: "~/sandbox/telar/site", status: "ready", lines: shellLines },
];

// What happens after a client attaches. Times are milliseconds since attach.
export const AGENT_SCRIPT: AgentEvent[] = [
  { at: 3200, id: "pi", patch: { title: "Explain the config", generated: true } },
  { at: 7200, id: "pi", patch: { status: "done", rang: true }, toast: { kind: "done", title: "Pi finished a turn", body: "Explain the config" } },
  { at: 9400, id: "bisect", patch: { status: "blocked" }, toast: { kind: "blocked", title: "Codex needs input", body: "Fix the flaky test" } },
  { at: 12200, id: "capture", patch: { status: "done", rang: true }, toast: { kind: "done", title: "Claude Code finished a turn", body: "Split proxy buffers" } },
];

/// `telar › proxy › pane 1`, the second row of every sidebar card.
export function location(agent: Agent): string {
  return `${WORKSPACE} › ${agent.tab} › pane ${agent.pane}`;
}
