// telar-integration: opencode
//
// Reports OpenCode's lifecycle, permission and question prompts, shell
// commands and session title to the Telar runtime that owns this pane, so the
// sidebar follows official events instead of screen heuristics. `telar
// integration install opencode` writes this file to
// ~/.config/opencode/plugins/telar.ts with the Telar executable path filled in.
// Outside a Telar pane the plugin does nothing.
import { spawn } from "node:child_process";

const TELAR = "__TELAR_EXECUTABLE__";

type Blocked = "permission" | "question";

type Report = {
  event: string;
  session_id?: string;
  busy?: boolean;
  blocked?: Blocked;
  title?: string;
  tool_name?: string;
  tool_call_id?: string;
  tool_input?: unknown;
  cwd?: string;
  exit_code?: number;
};

type SessionInfo = { id?: string; parentID?: string; title?: string };

// OpenCode starts one plugin instance per project directory it serves, all in
// the worker thread of one process, so the pane state lives at module scope.
const queue: string[] = [];
const drained: Array<() => void> = [];
let sending = false;
let instances = 0;
// The root session the pane shows; child sessions run the task tool's subagents.
let root: string | undefined;
const children = new Set<string>();
let busy = false;
const pending = new Map<string, Blocked>();
// The last state and title sent, so OpenCode's repeated `busy` statuses and
// `session.updated` touches spawn no process.
let reported = "";
let titled = "";
let refresh: ReturnType<typeof setInterval> | undefined;

// Serialize delivery: separate hook processes can otherwise report an old
// idle status after a newer busy one. Bound retained payloads and child
// lifetime; a saturated queue drops the oldest pending observation, never
// OpenCode's work.
const drain = () => {
  if (sending) return;
  const payload = queue.shift();
  if (payload === undefined) {
    for (const resolve of drained.splice(0)) resolve();
    return;
  }

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
    const child = spawn(TELAR, ["hook", "opencode"], { stdio: ["pipe", "ignore", "ignore"] });
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

const send = (report: Report) => {
  let bytes: string;
  try {
    bytes = JSON.stringify(report);
  } catch {
    return;
  }
  if (Buffer.byteLength(bytes) > 64 * 1024) return;
  if (queue.length === 32) queue.shift();
  queue.push(bytes);
  drain();
};

const blockedReason = (): Blocked | undefined => {
  let reason: Blocked | undefined;
  for (const kind of pending.values()) {
    if (kind === "permission") return kind;
    reason = kind;
  }
  return reason;
};

const stopRefresh = () => {
  clearInterval(refresh);
  refresh = undefined;
};

// Reports the pane's state when it changed, or always when the event names
// what the user is asked. A running turn or an open prompt renews it every 30
// seconds so the runtime never expires live work.
const report = (event: string, asked?: Pick<Report, "tool_name" | "tool_input">) => {
  const state: Report = { event, session_id: root, busy, blocked: blockedReason(), ...asked };
  const key = JSON.stringify([state.session_id, state.busy, state.blocked]);
  if (asked !== undefined || event === "state_snapshot" || key !== reported) {
    reported = key;
    send(state);
  }

  if (!busy && pending.size === 0) {
    stopRefresh();
  } else if (refresh === undefined) {
    refresh = setInterval(() => report("state_snapshot"), 30_000);
    refresh.unref();
  }
};

const isChild = (session: unknown) => typeof session === "string" && children.has(session);

const learn = (info: SessionInfo | undefined) => {
  if (typeof info?.id === "string" && info.parentID) children.add(info.id);
};

// A resumed session publishes nothing before its first prompt, so a rename
// then is the first sign of which session the TUI shows; the next prompt
// corrects it if the user renamed another one from the session list.
const reportTitle = (info: SessionInfo | undefined) => {
  if (root === undefined) adopt(info?.id);
  if (typeof info?.id !== "string" || info.id !== root || typeof info.title !== "string") return;
  const key = JSON.stringify([info.id, info.title]);
  if (key === titled) return;
  titled = key;
  send({ event: "session.updated", session_id: root, title: info.title });
};

const adopt = (session: unknown) => {
  if (typeof session !== "string" || !session || isChild(session) || session === root) return;
  root = session;
  busy = false;
  pending.clear();
};

export const TelarPlugin = async ({ directory }: { directory: string }) => {
  if (!process.env.TELAR_PANE_ID || !process.env.TELAR_PANE_GENERATION) {
    return {};
  }

  // OpenCode publishes nothing until the first prompt, not even for a resumed
  // session, so the first instance reports the idle TUI it starts as.
  instances++;
  if (instances === 1) report("load");

  // OpenCode runs each tool call of a step on its own and asks for
  // permission inside the tool, so a call can start while another one's
  // prompt is open; `blocked` tells the hook the prompt still stands.
  const reportTool = (event: string, input: { tool: string; sessionID: string; callID: string }, args: any, exit?: unknown) => {
    if (isChild(input.sessionID)) return;
    adopt(input.sessionID);
    send({
      event,
      session_id: root,
      blocked: blockedReason(),
      tool_name: input.tool,
      tool_call_id: input.callID,
      tool_input: args,
      cwd: typeof args?.workdir === "string" ? args.workdir : directory,
      exit_code: typeof exit === "number" ? exit : undefined,
    });
  };

  return {
    "chat.message": async (input: { sessionID: string }) => {
      if (isChild(input.sessionID)) return;
      adopt(input.sessionID);
      busy = true;
      report("chat.message");
    },
    "tool.execute.before": async (input: { tool: string; sessionID: string; callID: string }, output: { args: any }) =>
      reportTool("tool.execute.before", input, output.args),
    "tool.execute.after": async (input: { tool: string; sessionID: string; callID: string; args: any }, output: { metadata: any }) =>
      reportTool("tool.execute.after", input, input.args, output?.metadata?.exit),
    event: async ({ event }: { event: { type: string; properties: any } }) => {
      const properties = event.properties ?? {};
      switch (event.type) {
        case "session.created":
        case "session.updated":
          learn(properties.info);
          reportTitle(properties.info);
          return;
        case "session.status":
          if (isChild(properties.sessionID)) return;
          adopt(properties.sessionID);
          busy = properties.status?.type !== "idle";
          // An interrupt settles the turn without replying to its prompts.
          if (!busy) pending.clear();
          report(event.type);
          return;
        // A subagent's prompt blocks the pane too; it reports the root session.
        case "permission.asked":
          adopt(properties.sessionID);
          pending.set(properties.id, "permission");
          report(event.type, { tool_name: properties.permission, tool_input: properties.metadata });
          return;
        case "question.asked":
          adopt(properties.sessionID);
          pending.set(properties.id, "question");
          report(event.type, { tool_input: { questions: properties.questions } });
          return;
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          pending.delete(properties.requestID);
          report(event.type);
          return;
      }
    },
    // OpenCode disposes every instance before it exits and waits for this
    // promise, so the last one reports the exit before the process ends. A
    // reload (SIGUSR2, a configuration change) disposes them too, rejecting
    // open prompts without replies, and loads the plugin again from this
    // module, whose `load` must then reach the runtime.
    dispose: async () => {
      instances--;
      if (instances > 0) return;
      stopRefresh();
      busy = false;
      pending.clear();
      reported = "";
      send({ event: "dispose", session_id: root });
      await new Promise<void>((resolve) => {
        drained.push(resolve);
        setTimeout(resolve, 2500).unref();
        drain();
      });
    },
  };
};
