// `telar diagnostics limits` and the background runtime's log against a
// built telar, in a runtime of its own: a client reports a limit it reached
// and the command lists it. `node limits.test.mjs /path/to/telar`.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

assert.ok(process.argv[2], "usage: node limits.test.mjs /path/to/telar");
const telar = resolve(process.argv[2]);

const tags = { clientHello: 1, reportLimit: 0x43 };

function sandbox(t) {
  const root = mkdtempSync(join(tmpdir(), "telar-limits-"));
  const directory = (name) => {
    const path = join(root, name);
    mkdirSync(path, { mode: 0o700 });
    return path;
  };
  const env = {
    HOME: directory("home"),
    XDG_RUNTIME_DIR: directory("run"),
    XDG_STATE_HOME: directory("state"),
    XDG_CONFIG_HOME: directory("config"),
    XDG_DATA_HOME: directory("data"),
    XDG_CACHE_HOME: directory("cache"),
    PATH: "/usr/bin:/bin",
    SHELL: "/bin/sh",
  };
  const cli = (...args) => {
    const result = spawnSync(telar, args, { env, encoding: "utf8", timeout: 10_000 });
    if (result.error) throw result.error;
    return result;
  };
  t.after(() => {
    cli("server", "stop");
    rmSync(root, { recursive: true, force: true });
  });
  return { cli };
}

// One length-prefixed frame, as `localsocket.transport` writes it.
function frame(payload) {
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32LE(payload.length);
  return Buffer.concat([prefix, payload]);
}

function sized16(text) {
  const bytes = Buffer.from(text, "utf8");
  const prefix = Buffer.alloc(2);
  prefix.writeUInt16LE(bytes.length);
  return Buffer.concat([prefix, bytes]);
}

function u64(value) {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64LE(BigInt(value));
  return bytes;
}

function reportLimit({ name, noun, value, requested, hits }) {
  const count = Buffer.alloc(4);
  count.writeUInt32LE(hits);
  return Buffer.concat([
    Buffer.from([tags.reportLimit]),
    sized16(name),
    sized16(noun),
    u64(value),
    Buffer.from([1]),
    u64(requested),
    sized16(""),
    count,
  ]);
}

// Says hello with the runtime's schema, waits for its answer, sends the
// payloads and closes.
function sendAsClient(socket, schema, payloads) {
  return new Promise((resolvePromise, reject) => {
    const connection = connect(socket);
    const hello = Buffer.concat([Buffer.from("TELARIPC"), Buffer.from([tags.clientHello]), Buffer.from(schema)]);
    connection.once("error", reject);
    connection.once("connect", () => connection.write(frame(hello)));
    connection.once("data", () => {
      for (const payload of payloads) connection.write(frame(payload));
      connection.end(() => setTimeout(resolvePromise, 200));
    });
  });
}

test("a limit a client reports is listed by telar diagnostics limits, and the runtime logs to its own file", async (t) => {
  const s = sandbox(t);
  const started = s.cli("server", "--background", "--no-config");
  assert.equal(started.status, 0, started.stderr);

  const endpoint = s.cli("server", "endpoint");
  assert.equal(endpoint.status, 0, endpoint.stderr);
  const [socket, schema] = endpoint.stdout.trim().split("\n");

  const empty = s.cli("diagnostics", "limits", "--json");
  assert.equal(empty.status, 0, empty.stderr);
  assert.deepEqual(JSON.parse(empty.stdout).limits, []);

  await sendAsClient(socket, schema, [
    reportLimit({ name: "bars.max_bar_actions", noun: "click actions", value: 4, requested: 17, hits: 3 }),
  ]);

  const listed = s.cli("diagnostics", "limits", "--json");
  assert.equal(listed.status, 0, listed.stderr);
  const [entry] = JSON.parse(listed.stdout).limits;
  assert.equal(entry.name, "bars.max_bar_actions");
  assert.equal(entry.origin, "client");
  assert.equal(entry.hits, 3);
  assert.equal(entry.requested, 17);

  const text = s.cli("diagnostics", "limits");
  assert.match(text.stdout, /^bars\.max_bar_actions: 17 click actions; limit 4 \(3 times\)  \(client, last \d\d:\d\d:\d\d UTC\)\n$/);

  assert.ok(existsSync(`${socket}.runtime.start.log`), "the launch keeps what the runtime wrote before the listener");
  assert.ok(existsSync(`${socket}.runtime.log`), "the background runtime writes its own log");
  const logs = s.cli("diagnostics", "logs", "--component", "runtime");
  assert.equal(logs.status, 0, logs.stderr);
  assert.ok(logs.stdout.includes(`${socket}.runtime.log`), logs.stdout);
  assert.ok(logs.stdout.includes(`${socket}.runtime.start.log`), logs.stdout);
});
