import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const source = stripTypeScriptTypes(readFileSync(new URL("pi.ts", import.meta.url), "utf8")
  .replace(/^import .*;\n/gm, "")
  .replace("export default function", "globalThis.install = function"));

function fixture() {
  const handlers = new Map();
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
    process: { env: { TELAR_PANE_ID: "1", TELAR_PANE_GENERATION: "1" } },
    setInterval: (fn) => timer(intervals, fn),
    clearInterval: (item) => intervals.delete(item),
    setTimeout: (fn) => timer(timeouts, fn),
    clearTimeout: (item) => timeouts.delete(item),
    spawn() {
      const child = new EventEmitter();
      child.stdin = new EventEmitter();
      child.stdin.end = (payload) => { child.payload = JSON.parse(payload); };
      child.kill = (signal) => { child.killed = signal; child.emit("close"); };
      children.push(child);
      return child;
    },
  };
  runInNewContext(source, sandbox);
  sandbox.install({ on: (name, fn) => handlers.set(name, fn) });
  let idle = true;
  const ctx = {
    isIdle: () => idle,
    sessionManager: { getSessionId: () => "session", getSessionName: () => "name" },
  };
  return {
    children, intervals, timeouts,
    setIdle: (value) => { idle = value; },
    fire: (name, event = {}) => handlers.get(name)(event, ctx),
    tick: () => { for (const item of [...intervals]) item.fn(); },
    flush: () => { for (let i = 0; i < children.length; i++) children[i].emit("close"); },
  };
}

test("Pi delivers lifecycle reports in order with only one child in flight", async () => {
  const f = fixture();
  await f.fire("session_start");
  f.setIdle(false);
  await f.fire("agent_start");
  assert.equal(f.children.length, 1);
  f.children[0].emit("close");
  assert.equal(f.children.length, 2);
  assert.equal(f.children[1].payload.event, "agent_start");
  assert.equal(f.children[1].payload.idle, false);
});

test("Pi renews long runs, preserves nested dialogs and stops polling after settlement", async () => {
  const f = fixture();
  f.setIdle(false);
  await f.fire("agent_start");
  f.flush();
  for (let i = 0; i < 10; i++) { f.tick(); f.flush(); }
  assert.equal(f.children.at(-1).payload.event, "state_snapshot");
  assert.equal(f.children.at(-1).payload.idle, false);
  await f.fire("ui_prompt_start");
  await f.fire("ui_prompt_start");
  await f.fire("ui_prompt_end");
  f.flush();
  assert.equal(f.children.at(-1).payload.blocked, true);
  f.tick(); f.flush();
  assert.equal(f.children.at(-1).payload.blocked, true);
  await f.fire("ui_prompt_end");
  f.setIdle(true);
  await f.fire("agent_settled");
  f.flush();
  assert.equal(f.children.at(-1).payload.idle, true);
  assert.equal(f.intervals.size, 0);
});

test("Pi bounds overload, kills hung hooks and retains the latest state", async () => {
  const f = fixture();
  await f.fire("session_start");
  for (let i = 0; i < 100; i++) await f.fire("agent_start");
  await f.fire("agent_settled");
  assert.equal(f.children.length, 1);
  [...f.timeouts][0].fn();
  assert.equal(f.children[0].killed, "SIGKILL");
  f.flush();
  assert.equal(f.children.length, 33);
  assert.equal(f.children.at(-1).payload.event, "agent_settled");
  assert.equal(f.timeouts.size, 0);
});

test("Pi repairs a missing settled callback and cancels renewal on shutdown", async () => {
  const f = fixture();
  f.setIdle(false);
  await f.fire("agent_start");
  f.flush();
  f.setIdle(true);
  f.tick(); f.flush();
  assert.equal(f.children.at(-1).payload.idle, true);
  assert.equal(f.intervals.size, 0);
  f.setIdle(false);
  await f.fire("agent_start");
  await f.fire("session_shutdown");
  f.flush();
  assert.equal(f.intervals.size, 0);
  assert.equal(f.children.at(-1).payload.event, "session_shutdown");
});
