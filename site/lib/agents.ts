// The demo window's data, shaped after a real telar session: one host, three
// workspaces in the top bar, the open workspace's tabs in the bottom bar, and
// agents whose cards follow the sidebar contract in docs/sidebar.md (title
// and status, workspace › tab › pane, provider · cwd). Everything is scripted.

export type Provider = "claude" | "codex" | "pi";

export type AgentStatus = "working" | "blocked" | "ready" | "done";

export type Line = { at: number; text: string; tone?: "dim" | "ok" | "warn" | "accent" | "prompt" | "key" };

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

/// A pane in a tab. Agent panes take their content from the agent; the
/// others show a static program so the split looks like a working desk.
export type Pane = { tab: string; number: number; title: string; agent?: string; lines?: Line[] };

export type ToastKind = "done" | "blocked";

export type AgentEvent = {
  at: number;
  id: string;
  patch: Partial<Agent>;
  toast?: { kind: ToastKind; title: string; body: string };
};

export const HOST = "minions";

export const WORKSPACES = ["telar", "valhalla", "cambria"];

export const WORKSPACE = WORKSPACES[0];

export const TABS = ["agents", "editor", "research", "website"];

// The quota badges telar's top bar shows per provider while the proxy is on.
export const USAGE: { provider: Provider; label: string; text: string }[] = [
  { provider: "codex", label: "CX", text: "7d:45%" },
  { provider: "claude", label: "CL", text: "5h:8% 7d:2% F:4%" },
];

// Mirrors src/frontend/ui/icons.zig and src/frontend/assets.
export const PROVIDERS: Record<Provider, { name: string; short: string; mark: string; tone: string }> = {
  claude: { name: "Claude Code", short: "claude", mark: "/brand/providers/claude.png", tone: "text-chrome-accent" },
  codex: { name: "Codex", short: "codex", mark: "/brand/providers/codex.png", tone: "text-chrome-subtext" },
  pi: { name: "Pi", short: "pi", mark: "/brand/providers/pi.svg", tone: "text-chrome-teal" },
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
    glyph: "?",
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
  { at: 0, text: "✻ Claude Code v2.1  ·  ~/sandbox/telar  ·  main", tone: "accent" },
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
  { at: 0, text: "OpenAI Codex  ·  ~/sandbox/telar  ·  perf/echo", tone: "accent" },
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
  { at: 0, text: "pi v0.85.1", tone: "accent" },
  { at: 60, text: "escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash · ctrl+o more", tone: "dim" },
  { at: 120, text: "" },
  { at: 180, text: "[Context]", tone: "key" },
  { at: 200, text: "  ~/.pi/agent/AGENTS.md, AGENTS.md", tone: "dim" },
  { at: 240, text: "[Skills]", tone: "key" },
  { at: 260, text: "  domain-modeling, grilling, nvim, review, terminal-browser, unslop", tone: "dim" },
  { at: 300, text: "[Extensions]", tone: "key" },
  { at: 320, text: "  telar.ts", tone: "dim" },
  { at: 360, text: "[Themes]", tone: "key" },
  { at: 380, text: "  vesper", tone: "dim" },
  { at: 440, text: "" },
  { at: 500, text: "✓ New session started", tone: "ok" },
  { at: 1400, text: "» explain runtime.proxy in config.lua", tone: "prompt" },
  { at: 2600, text: "  reading docs/proxy-tls.md", tone: "dim" },
  { at: 4000, text: "  `enabled` starts the loopback listener on ports 45100–45227." },
  { at: 5200, text: "  `intercept_hosts` replaces the default allowlist of model APIs." },
  { at: 6400, text: "  `capture.enabled` turns on bounded exchange buffers for plugins." },
  { at: 7800, text: "  Everything else is passed through byte for byte.", tone: "ok" },
];

const researchLines: Line[] = [
  { at: 0, text: "✻ Claude Code v2.1  ·  ~/sandbox/telar  ·  main", tone: "accent" },
  { at: 300, text: "❯ compare agent mode layouts in T3 Code, herdr and cmux", tone: "prompt" },
  { at: 1600, text: "● WebFetch t3.gg/code", tone: "dim" },
  { at: 2600, text: "● WebFetch herdr.dev", tone: "dim" },
  { at: 4200, text: "  All three put threads in a left column and the conversation in the middle." },
  { at: 5600, text: "  Only cmux keeps the terminal visible beside the conversation." },
  { at: 7000, text: "● Write docs/plans/agent-mode/layouts.md", tone: "dim" },
  { at: 8200, text: "  Written. Three layouts, one recommendation: A, three columns.", tone: "ok" },
];

const nvimLines: Line[] = [
  { at: 0, text: "  terminal.zig   bitmap.zig ×   presentation/presenter.zig", tone: "dim" },
  { at: 40, text: " 15  pub fn sample(source: Bitmap, point: Point, size: u32) [4]u8 {" },
  { at: 60, text: " 14      const x: Axis = axis(destination: point.x, destination_size: size);" },
  { at: 80, text: " 13      const y: Axis = axis(destination: point.y, destination_size: size);" },
  { at: 100, text: " 12      const weights: [4]u64 = [4]u64{" },
  { at: 120, text: " 11          (one - x.fraction) * (one - y.fraction)," },
  { at: 140, text: " 10          x.fraction * (one - y.fraction)," },
  { at: 160, text: "  9          (one - x.fraction) * y.fraction," },
  { at: 180, text: "  8          x.fraction * y.fraction," },
  { at: 200, text: "  7      };" },
  { at: 220, text: "  6      const pixels: [4][4]u8 = [4][4]u8{" },
  { at: 240, text: "  5          source.pixel(x: x.index, y: y.index)," },
  { at: 260, text: "  4          source.pixel(x: x.next, y: y.index)," },
  { at: 280, text: "  3          source.pixel(x: x.index, y: y.next)," },
  { at: 300, text: "  2          source.pixel(x: x.next, y: y.next)," },
  { at: 320, text: "  1      };" },
  { at: 340, text: "▸57      const total_weight: u64 = one * one;", tone: "accent" },
  { at: 360, text: "  1      var alpha_sum: u64 = 0;" },
  { at: 380, text: "  2      var premultiplied: [3]u64 = @splat(0);" },
  { at: 400, text: "" },
  { at: 420, text: " NORMAL   main   src/…/graphics/bitmap.zig                      48%  57:1 ", tone: "key" },
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
  { id: "capture", title: "Split proxy buffers", provider: "claude", tab: "agents", pane: 1, cwd: "~/sandbox/telar", status: "working", lines: claudeLines },
  { id: "pi", title: "New Pi session", provider: "pi", tab: "editor", pane: 2, cwd: "~/sandbox/telar", status: "working", lines: piLines },
  { id: "bisect", title: "Fix the flaky test", provider: "codex", tab: "research", pane: 1, cwd: "~/sandbox/telar", status: "working", lines: codexLines },
  { id: "layouts", title: "Compare agent mode layouts", provider: "claude", tab: "research", pane: 2, cwd: "~/sandbox/telar", status: "ready", lines: researchLines },
];

export const PANES: Pane[] = [
  { tab: "agents", number: 1, title: "claude", agent: "capture" },
  { tab: "editor", number: 1, title: "nvim", lines: nvimLines },
  { tab: "editor", number: 2, title: "pi", agent: "pi" },
  { tab: "research", number: 1, title: "codex", agent: "bisect" },
  { tab: "research", number: 2, title: "claude", agent: "layouts" },
  { tab: "website", number: 1, title: "zsh", lines: shellLines },
];

// What happens after a client attaches. Times are milliseconds since attach.
export const AGENT_SCRIPT: AgentEvent[] = [
  { at: 3200, id: "pi", patch: { title: "Explain the config", generated: true } },
  { at: 8200, id: "pi", patch: { status: "done", rang: true }, toast: { kind: "done", title: "Pi finished a turn", body: "Explain the config" } },
  { at: 9400, id: "bisect", patch: { status: "blocked" }, toast: { kind: "blocked", title: "Codex needs input", body: "Fix the flaky test" } },
  { at: 12200, id: "capture", patch: { status: "done", rang: true }, toast: { kind: "done", title: "Claude Code finished a turn", body: "Split proxy buffers" } },
];

/// `telar › agents › pane 1`, the second row of every sidebar card.
export function location(agent: Agent): string {
  return `${WORKSPACE} › ${agent.tab} › pane ${agent.pane}`;
}

export function panesOfTab(tab: string): Pane[] {
  return PANES.filter((pane) => pane.tab === tab);
}
