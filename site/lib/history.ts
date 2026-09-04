export type Scope = "global" | "workspace" | "cwd" | "pane";

export const SCOPES: Scope[] = ["global", "workspace", "cwd", "pane"];

export type HistoryRow = { cmd: string; workspace: string; cwd: string; pane: number; agent?: boolean };

export const HISTORY: HistoryRow[] = [
  { cmd: "zig build test -Dtest-filter=proxy", workspace: "telar", cwd: "~/sandbox/telar", pane: 1 },
  { cmd: "zig build run -- --theme vesper", workspace: "telar", cwd: "~/sandbox/telar", pane: 2 },
  { cmd: "bundle exec rspec spec/webhooks", workspace: "guruwalk", cwd: "~/work/api", pane: 1, agent: true },
  { cmd: "git log --oneline -20", workspace: "telar", cwd: "~/sandbox/telar/docs", pane: 1 },
  { cmd: "just coverage", workspace: "telar", cwd: "~/sandbox/telar", pane: 1 },
  { cmd: "rails db:migrate", workspace: "guruwalk", cwd: "~/work/api", pane: 2 },
  { cmd: "zig-crap src --lcov coverage.lcov", workspace: "telar", cwd: "~/sandbox/telar", pane: 2 },
  { cmd: "npm run build", workspace: "telar", cwd: "~/sandbox/telar/site", pane: 1 },
];

export const HERE = { workspace: "telar", cwd: "~/sandbox/telar", pane: 1 };

export function inScope(row: HistoryRow, scope: Scope): boolean {
  switch (scope) {
    case "global":
      return true;
    case "workspace":
      return row.workspace === HERE.workspace;
    case "cwd":
      return row.cwd === HERE.cwd;
    case "pane":
      return row.cwd === HERE.cwd && row.pane === HERE.pane;
  }
}
