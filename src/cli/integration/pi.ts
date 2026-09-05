// telar-integration: pi
//
// Reports Pi's own lifecycle and session name to the Telar runtime that owns
// this pane, so the sidebar shows working, blocked, ready and the `/name`
// title from official events instead of screen heuristics. `telar integration install pi` writes this file to
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
  | "session_shutdown"
  | "state_snapshot";

type ToolEvent = "tool_execution_start" | "tool_execution_end";

export default function (pi: ExtensionAPI) {
  if (!process.env.TELAR_PANE_ID || !process.env.TELAR_PANE_GENERATION) {
    return;
  }

  // Serialize delivery: separate hook processes can otherwise report an old
  // ready event after a newer start. Bound retained payloads and child lifetime;
  // a saturated queue drops the oldest pending observation, never Pi's work.
  const queue: string[] = [];
  let sending = false;
  const drain = () => {
    if (sending || queue.length === 0) return;
    const payload = queue.shift()!;
    sending = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      sending = false;
      drain();
    };
    try {
      const child = spawn(TELAR, ["hook", "pi"], { stdio: ["pipe", "ignore", "ignore"] });
      child.once("error", finish);
      child.once("close", finish);
      child.stdin.on("error", () => {});
      timer = setTimeout(() => child.kill("SIGKILL"), 2000);
      timer.unref();
      child.stdin.end(payload);
    } catch {
      finish();
    }
  };
  const send = (payload: Record<string, unknown>) => {
    let bytes: string;
    try {
      bytes = JSON.stringify(payload);
    } catch {
      return;
    }
    if (Buffer.byteLength(bytes) > 64 * 1024) return;
    if (queue.length === 32) queue.shift();
    queue.push(bytes);
    drain();
  };

  let refresh: ReturnType<typeof setInterval> | undefined;
  let promptDepth = 0;
  const stopRefresh = () => {
    clearInterval(refresh);
    refresh = undefined;
  };
  const keepCurrent = (ctx: ExtensionContext) => {
    stopRefresh();
    refresh = setInterval(() => {
      report("state_snapshot", ctx);
      if (ctx.isIdle() && promptDepth === 0) stopRefresh();
    }, 30_000);
    refresh.unref();
  };

  const report = (event: Event, ctx: ExtensionContext, idle?: boolean) =>
    send({
      event,
      session_id: ctx.sessionManager.getSessionId(),
      idle: idle ?? ctx.isIdle(),
      blocked: promptDepth > 0,
      name: ctx.sessionManager.getSessionName() || undefined,
    });

  // The name the user gave the session with `/name`; `undefined` once cleared.
  const reportName = (name: string | undefined, ctx: ExtensionContext) =>
    send({
      event: "session_info_changed",
      session_id: ctx.sessionManager.getSessionId(),
      name,
    });

  const pendingTools = new Map<string, { toolName: string; args: unknown }>();
  const reportTool = (event: ToolEvent, ctx: ExtensionContext, toolCallId: string, toolName: string, args: unknown, exitCode?: number) =>
    send({
      event,
      session_id: ctx.sessionManager.getSessionId(),
      tool_name: toolName,
      tool_call_id: toolCallId,
      tool_input: args,
      cwd: ctx.cwd,
      exit_code: exitCode,
    });

  pi.on("session_start", async (_event, ctx) => {
    promptDepth = 0;
    stopRefresh();
    report("session_start", ctx);
    if (!ctx.isIdle()) keepCurrent(ctx);
  });
  pi.on("agent_start", async (_event, ctx) => {
    report("agent_start", ctx, false);
    keepCurrent(ctx);
  });
  pi.on("agent_settled", async (_event, ctx) => {
    report("agent_settled", ctx);
    if (ctx.isIdle() && promptDepth === 0) stopRefresh();
  });
  pi.on("ui_prompt_start", async (_event, ctx) => {
    promptDepth++;
    report("ui_prompt_start", ctx);
    keepCurrent(ctx);
  });
  pi.on("ui_prompt_end", async (_event, ctx) => {
    promptDepth = Math.max(0, promptDepth - 1);
    report("ui_prompt_end", ctx);
    if (ctx.isIdle() && promptDepth === 0) stopRefresh();
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    stopRefresh();
    report("session_shutdown", ctx);
  });
  pi.on("session_info_changed", async (event, ctx) => reportName(event.name, ctx));
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
