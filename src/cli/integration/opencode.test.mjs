import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const source = stripTypeScriptTypes(readFileSync(new URL("opencode.ts", import.meta.url), "utf8")
  .replace(/^import .*;\n/gm, "")
  .replace("export const TelarPlugin =", "globalThis.TelarPlugin ="));

const root = "ses_f212d4cc3ffeR3t3CA08EwN5Ap";
const child = "ses_f212c0000000aaaaaaaaaaaaaa";

// Each fixture evaluates the plugin afresh, so its module state starts empty.
async function fixture(env = { TELAR_PANE_ID: "1", TELAR_PANE_GENERATION: "1" }) {
  const children = [];
  const intervals = new Set();
  const timeouts = new Set();
  const timer = (set, fn) => {
    const item = { fn, unref() {} };
    set.add(item);
    return item;
  };
  const sandbox = {
    Buffer,
    process: { env },
    setInterval: (fn) => timer(intervals, fn),
    clearInterval: (item) => intervals.delete(item),
    setTimeout: (fn) => timer(timeouts, fn),
    clearTimeout: (item) => timeouts.delete(item),
    spawn(command, args) {
      const process = new EventEmitter();
      process.args = args;
      process.stdin = new EventEmitter();
      process.stdin.end = (payload) => { process.payload = JSON.parse(payload); };
      process.kill = (signal) => { process.killed = signal; process.emit("close"); };
      children.push(process);
      return process;
    },
  };
  runInNewContext(source, sandbox);
  const hooks = await sandbox.TelarPlugin({ directory: "/work/proj" });
  const flush = () => { for (let i = 0; i < children.length; i++) children[i].emit("close"); };
  // Every test starts after the report of the idle TUI the plugin loads into.
  const load = children.splice(0).map((process) => { process.emit("close"); return process.payload; });
  return {
    load,
    plugin: () => sandbox.TelarPlugin({ directory: "/work/proj" }),
    hooks, children, intervals, timeouts, flush,
    event: (type, properties) => hooks.event({ event: { type, properties } }),
    payloads: () => { flush(); return children.map((process) => process.payload); },
    tick: () => { for (const item of [...intervals]) item.fn(); },
  };
}

test("OpenCode does nothing outside a Telar pane", async () => {
  const f = await fixture({});
  assert.equal(JSON.stringify(f.hooks), "{}");
  assert.equal(f.load.length, 0);
});

test("OpenCode reports the idle TUI it loads into", async () => {
  const f = await fixture();
  assert.equal(f.load.length, 1);
  assert.equal(f.load[0].event, "load");
  assert.equal(f.load[0].busy, false);
  assert.equal(f.load[0].session_id, undefined);
});

test("OpenCode reports a turn once per state change, not per repeated status", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  for (let i = 0; i < 4; i++) await f.event("session.status", { sessionID: root, status: { type: "busy" } });
  await f.event("session.status", { sessionID: root, status: { type: "idle" } });
  await f.event("session.idle", { sessionID: root });
  const payloads = f.payloads();
  assert.deepEqual(payloads.map((payload) => [payload.event, payload.busy]), [["chat.message", true], ["session.status", false]]);
  assert.equal(payloads[0].session_id, root);
  assert.equal(JSON.stringify(f.children[0].args), JSON.stringify(["hook", "opencode"]));
  assert.equal(f.intervals.size, 0);
});

test("OpenCode blocks on a permission until it is answered or the turn is interrupted", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  await f.event("permission.asked", {
    id: "per_1", sessionID: root, permission: "bash", patterns: ["ls -la"],
    metadata: { command: "ls -la" }, always: ["ls *"], tool: { messageID: "msg_1", callID: "call-1" },
  });
  await f.event("permission.replied", { sessionID: root, requestID: "per_1", reply: "once" });
  await f.event("permission.asked", { id: "per_2", sessionID: root, permission: "bash", metadata: { command: "sleep 30" } });
  // ESC twice aborts the turn: OpenCode sends no reply for the open prompt.
  await f.event("session.error", { sessionID: root, error: { name: "MessageAbortedError", data: { message: "Aborted" } } });
  await f.event("session.status", { sessionID: root, status: { type: "idle" } });
  const [, asked, replied, again, settled] = f.payloads();
  assert.equal(asked.event, "permission.asked");
  assert.equal(asked.blocked, "permission");
  assert.equal(asked.tool_name, "bash");
  assert.deepEqual(asked.tool_input, { command: "ls -la" });
  assert.equal(replied.blocked, undefined);
  assert.equal(replied.busy, true);
  assert.equal(again.blocked, "permission");
  assert.equal(settled.busy, false);
  assert.equal(settled.blocked, undefined);
  assert.equal(f.children.length, 5);
});

test("OpenCode questions block with their questions and a rejection releases them", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  const questions = [{ question: "Which database?", header: "Database", options: [{ label: "SQLite", description: "Local" }] }];
  await f.event("question.asked", { id: "que_1", sessionID: root, questions });
  await f.event("question.rejected", { sessionID: root, requestID: "que_1" });
  const [, asked, rejected] = f.payloads();
  assert.equal(asked.blocked, "question");
  assert.deepEqual(asked.tool_input, { questions });
  assert.equal(rejected.blocked, undefined);
});

test("OpenCode subagent sessions never replace the root, but their prompts block it", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  await f.event("session.created", { sessionID: child, info: { id: child, parentID: root, title: "Child session - 2026-09-26T17:45:45.532Z" } });
  await f.hooks["chat.message"]({ sessionID: child });
  await f.event("session.status", { sessionID: child, status: { type: "idle" } });
  await f.hooks["tool.execute.before"]({ tool: "bash", sessionID: child, callID: "call-2" }, { args: { command: "ls" } });
  await f.event("permission.asked", { id: "per_3", sessionID: child, permission: "edit", metadata: { filepath: "a.txt" } });
  const payloads = f.payloads();
  assert.deepEqual(payloads.map((payload) => payload.event), ["chat.message", "permission.asked"]);
  assert.equal(payloads[1].session_id, root);
  assert.equal(payloads[1].blocked, "permission");
});

test("OpenCode reports the root session's title once per change", async () => {
  const f = await fixture();
  const info = (title) => ({ sessionID: root, info: { id: root, title } });
  await f.event("session.updated", info("New session - 2026-09-26T17:45:45.532Z"));
  await f.hooks["chat.message"]({ sessionID: root });
  await f.event("session.updated", info("New session - 2026-09-26T17:45:45.532Z"));
  await f.event("session.updated", info("New session - 2026-09-26T17:45:45.532Z"));
  await f.event("session.updated", info("Fix proxy lifecycle"));
  await f.event("session.updated", { sessionID: child, info: { id: child, title: "Another session" } });
  const titles = f.payloads().filter((payload) => payload.event === "session.updated").map((payload) => payload.title);
  assert.deepEqual(titles, ["New session - 2026-09-26T17:45:45.532Z", "Fix proxy lifecycle"]);
});

test("OpenCode titles a resumed session renamed before its first prompt", async () => {
  const f = await fixture();
  await f.event("session.updated", { sessionID: child, info: { id: child, parentID: root, title: "Subagent" } });
  await f.event("session.updated", { sessionID: root, info: { id: root, title: "Trace OpenCode events" } });
  const [renamed] = f.payloads();
  assert.equal(renamed.event, "session.updated");
  assert.equal(renamed.session_id, root);
  assert.equal(renamed.title, "Trace OpenCode events");
  assert.equal(f.children.length, 1);
});

test("OpenCode tool calls carry their arguments, directory and exit status", async () => {
  const f = await fixture();
  const call = { tool: "bash", sessionID: root, callID: "call-b28da335" };
  await f.hooks["tool.execute.before"](call, { args: { command: "echo hello-telar && false" } });
  await f.hooks["tool.execute.after"]({ ...call, args: { command: "echo hello-telar && false", workdir: "/work/sub" } },
    { title: "echo", output: "hello-telar\n", metadata: { output: "hello-telar\n", exit: 1, truncated: false } });
  await f.hooks["tool.execute.after"]({ ...call, callID: "call-aborted", args: { command: "sleep 30" } },
    { title: "sleep 30", output: "", metadata: { exit: null } });
  const [before, after, aborted] = f.payloads();
  assert.equal(before.event, "tool.execute.before");
  assert.equal(before.session_id, root);
  assert.equal(before.tool_call_id, "call-b28da335");
  assert.equal(before.cwd, "/work/proj");
  assert.equal(before.exit_code, undefined);
  assert.equal(after.cwd, "/work/sub");
  assert.equal(after.exit_code, 1);
  assert.equal(aborted.exit_code, undefined);
});

test("OpenCode renews a running turn and an open prompt, then stops", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  f.tick(); f.tick();
  assert.deepEqual(f.payloads().slice(1).map((payload) => [payload.event, payload.busy]), [["state_snapshot", true], ["state_snapshot", true]]);
  await f.event("session.status", { sessionID: root, status: { type: "idle" } });
  assert.equal(f.intervals.size, 0);
});

test("OpenCode bounds overload, kills hung hooks and keeps the latest state", async () => {
  const f = await fixture();
  for (let i = 0; i < 100; i++) await f.hooks["tool.execute.before"]({ tool: "read", sessionID: root, callID: `call-${i}` }, { args: {} });
  await f.event("session.status", { sessionID: root, status: { type: "idle" } });
  assert.equal(f.children.length, 1);
  [...f.timeouts][0].fn();
  assert.equal(f.children[0].killed, "SIGKILL");
  f.flush();
  assert.equal(f.children.length, 33);
  assert.equal(f.children.at(-1).payload.event, "session.status");
});

test("OpenCode reports the exit from the last disposed instance and waits for delivery", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  let done = false;
  const disposed = f.hooks.dispose().then(() => { done = true; });
  await Promise.resolve();
  assert.equal(done, false);
  f.flush();
  await disposed;
  assert.deepEqual(f.children.map((process) => process.payload.event), ["chat.message", "dispose"]);
  assert.equal(f.children[1].payload.session_id, root);
  assert.equal(f.intervals.size, 0);
});

test("OpenCode keeps an open permission while another tool call of the turn starts", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  await f.hooks["tool.execute.before"]({ tool: "bash", sessionID: root, callID: "call-1" }, { args: { command: "rm -rf build" } });
  await f.event("permission.asked", { id: "per_1", sessionID: root, permission: "bash", metadata: { command: "rm -rf build" } });
  // OpenCode runs each call of a step on its own, and asks inside the tool, after this hook.
  await f.hooks["tool.execute.before"]({ tool: "read", sessionID: root, callID: "call-2" }, { args: { filePath: "/work/proj/README.md" } });
  await f.event("permission.replied", { sessionID: root, requestID: "per_1", reply: "once" });
  const [, first, asked, second, replied] = f.payloads();
  assert.equal(first.blocked, undefined);
  assert.equal(asked.blocked, "permission");
  assert.equal(second.event, "tool.execute.before");
  assert.equal(second.blocked, "permission");
  assert.equal(replied.blocked, undefined);
  assert.equal(replied.busy, true);
});

test("OpenCode reports the idle TUI again when it recreates its instances", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  await f.event("permission.asked", { id: "per_1", sessionID: root, permission: "bash", metadata: { command: "ls" } });
  // A reload (SIGUSR2, a config change) disposes every instance, which
  // rejects open prompts without replies, then loads the plugin again from
  // the same module.
  const disposed = f.hooks.dispose();
  f.flush();
  await disposed;
  await f.plugin();
  const payloads = f.payloads();
  assert.deepEqual(payloads.map((payload) => payload.event), ["chat.message", "permission.asked", "dispose", "load"]);
  assert.equal(payloads[3].busy, false);
  assert.equal(payloads[3].blocked, undefined);
  assert.equal(payloads[3].session_id, root);
  assert.equal(f.intervals.size, 0);
});

test("OpenCode trims a prompt too large to deliver instead of dropping it", async () => {
  const f = await fixture();
  await f.hooks["chat.message"]({ sessionID: root });
  const diff = "+" + "x".repeat(80 * 1024);
  await f.event("permission.asked", { id: "per_1", sessionID: root, permission: "edit", metadata: { filepath: "/work/proj/big.txt", diff } });
  await f.hooks["tool.execute.before"]({ tool: "write", sessionID: root, callID: "call-1" }, { args: { filePath: "/work/proj/big.txt", content: diff } });
  const [, asked, write] = f.payloads();
  assert.equal(asked.event, "permission.asked");
  assert.equal(asked.blocked, "permission");
  assert.deepEqual(asked.tool_input, { filepath: "/work/proj/big.txt" });
  assert.deepEqual(write.tool_input, { filePath: "/work/proj/big.txt" });
  for (const child of f.children) assert.ok(Buffer.byteLength(JSON.stringify(child.payload)) <= 64 * 1024);
});

test("OpenCode trims every question but the first from an oversized prompt", async () => {
  const f = await fixture();
  const questions = Array.from({ length: 40 }, (_, i) => ({ question: `Question ${i}?`, header: "H", options: [{ label: "x".repeat(2048), description: "" }] }));
  await f.event("question.asked", { id: "que_1", sessionID: root, questions });
  const [asked] = f.payloads();
  assert.equal(asked.blocked, "question");
  assert.deepEqual(asked.tool_input, { questions: [{ question: "Question 0?" }] });
});
