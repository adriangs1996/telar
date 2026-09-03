// telar-integration: pi
//
// Reports Pi's own lifecycle to the Telar runtime that owns this pane, so the
// sidebar shows working, blocked and ready from official events instead of
// screen heuristics. `telar integration install pi` writes this file to
// ~/.pi/agent/extensions/telar.ts with the Telar executable path filled in.
// Outside a Telar pane the extension does nothing.
import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const TELAR = "__TELAR_EXECUTABLE__";

type Event =
  | "session_start"
  | "agent_start"
  | "agent_settled"
  | "ui_prompt_start"
  | "ui_prompt_end"
  | "session_shutdown";

type ToolEvent = "tool_execution_start" | "tool_execution_end";

export default function (pi: ExtensionAPI) {
  if (!process.env.TELAR_PANE_ID || !process.env.TELAR_PANE_GENERATION) {
    return;
  }

  // One short-lived `telar hook pi` per event; it exits 0 whatever happens
  // so Pi is never affected by a missing or unreachable runtime.
  const report = (event: Event, ctx: ExtensionContext, idle?: boolean) => {
    const payload = JSON.stringify({
      event,
      session_id: ctx.sessionManager.getSessionId(),
      idle: idle ?? ctx.isIdle(),
    });
    try {
      const child = spawn(TELAR, ["hook", "pi"], { stdio: ["pipe", "ignore", "ignore"] });
      child.on("error", () => {});
      child.stdin.on("error", () => {});
      child.stdin.end(payload);
    } catch {
      // Telar is absent; nothing to report to.
    }
  };

  const pendingTools = new Map<string, { toolName: string; args: unknown }>();
  const reportTool = (event: ToolEvent, ctx: ExtensionContext, toolCallId: string, toolName: string, args: unknown, exitCode?: number) => {
    const payload = JSON.stringify({
      event,
      session_id: ctx.sessionManager.getSessionId(),
      tool_name: toolName,
      tool_call_id: toolCallId,
      tool_input: args,
      cwd: ctx.cwd,
      exit_code: exitCode,
    });
    try {
      const child = spawn(TELAR, ["hook", "pi"], { stdio: ["pipe", "ignore", "ignore"] });
      child.on("error", () => {});
      child.stdin.on("error", () => {});
      child.stdin.end(payload);
    } catch {
      // Telar is absent; nothing to report to.
    }
  };

  pi.on("session_start", async (_event, ctx) => report("session_start", ctx, true));
  pi.on("agent_start", async (_event, ctx) => report("agent_start", ctx, false));
  pi.on("agent_settled", async (_event, ctx) => report("agent_settled", ctx, true));
  pi.on("ui_prompt_start", async (_event, ctx) => report("ui_prompt_start", ctx));
  pi.on("ui_prompt_end", async (_event, ctx) => report("ui_prompt_end", ctx));
  pi.on("session_shutdown", async (_event, ctx) => report("session_shutdown", ctx));
  pi.on("tool_execution_start", async (event, ctx) => {
    pendingTools.set(event.toolCallId, { toolName: event.toolName, args: event.args });
    reportTool("tool_execution_start", ctx, event.toolCallId, event.toolName, event.args);
  });
  pi.on("tool_execution_end", async (event, ctx) => {
    const pending = pendingTools.get(event.toolCallId);
    pendingTools.delete(event.toolCallId);
    if (pending) {
      reportTool("tool_execution_end", ctx, event.toolCallId, pending.toolName, pending.args, event.isError ? 1 : 0);
    }
  });
}
