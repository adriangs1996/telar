// The CLI's raised limits against a built telar, in a runtime of its own:
// a long command line, a launch past the old 8 KiB request buffer, 64 KiB
// sent to a pane and a 2000-row read, and the limit notice one step past
// each bound. `node cli_limits.test.mjs /path/to/telar`.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

assert.ok(process.argv[2], "usage: node cli_limits.test.mjs /path/to/telar");
const telar = resolve(process.argv[2]);

// The wire's bounds, as `telar api` would list them.
const maxArgumentCount = 64;
const maxPaneTextInputBytes = 64 * 1024;
const maxPaneTextRows = 2000;

function sandbox(t) {
  const root = mkdtempSync(join(tmpdir(), "telar-cli-limits-"));
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
  const work = directory("work");
  const cli = (args, input) => {
    const result = spawnSync(telar, args, { env, encoding: "utf8", input, timeout: 20_000, maxBuffer: 16 * 1024 * 1024 });
    if (result.error) throw result.error;
    return result;
  };
  t.after(() => {
    cli(["server", "stop"]);
    rmSync(root, { recursive: true, force: true });
  });
  return { cli, work };
}

// A workspace whose one pane keeps running without reading its input.
function createPane(cli, work, extra = []) {
  const created = cli(["workspace", "create", "--directory", work, "--json", "--", "/bin/sh", "-c", "sleep 60", "sh", ...extra]);
  assert.equal(created.status, 0, created.stderr);
  return JSON.parse(created.stdout).pane_id;
}

test("a command line longer than 64 words is read whole and named by its own bound", (t) => {
  const { cli, work } = sandbox(t);
  const words = Array.from({ length: maxArgumentCount + 10 }, (_, index) => `w${index}`);

  const result = cli(["workspace", "create", "--directory", work, "--", "/bin/echo", ...words]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Limit reached: cli\.workspace_command_words: 75 words; limit 64/);
  assert.doesNotMatch(result.stderr, /TooManyArguments/);
});

test("a launch past the old 8 KiB request buffer creates its workspace", (t) => {
  const { cli, work } = sandbox(t);
  const long = Array.from({ length: 16 }, () => "x".repeat(1024));

  assert.ok(createPane(cli, work, long) > 0);
});

test("64 KiB reaches a pane and one byte more is refused by name", (t) => {
  const { cli, work } = sandbox(t);
  const pane = String(createPane(cli, work));

  const whole = cli(["pane", "send-keys", pane, "--stdin"], "y".repeat(maxPaneTextInputBytes));
  assert.equal(whole.status, 0, whole.stderr);

  const over = cli(["pane", "send-keys", pane, "--stdin"], "y".repeat(maxPaneTextInputBytes + 1));
  assert.notEqual(over.status, 0);
  assert.match(over.stderr, /send-keys needs text of 1 to 65536 bytes/);
});

test("a read asks for 2000 rows and no more", (t) => {
  const { cli, work } = sandbox(t);
  const pane = String(createPane(cli, work));

  const read = cli(["pane", "read", pane, "--lines", String(maxPaneTextRows), "--json"]);
  assert.equal(read.status, 0, read.stderr);
  assert.equal(JSON.parse(read.stdout).pane_id, Number(pane));

  const over = cli(["pane", "read", pane, "--lines", String(maxPaneTextRows + 1)]);
  assert.notEqual(over.status, 0);
});
