// Discovery from a built telar alone, in a throwaway home with no runtime:
// the root help maps the families, every family lists its commands and every
// listed command explains itself; an unknown word points at the help to
// read; a `--help` after `--` is the child's; and none of it starts or
// contacts a runtime. `node help.test.mjs /path/to/telar`.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { test } from "node:test";

assert.ok(process.argv[2], "usage: node help.test.mjs /path/to/telar");
const telar = resolve(process.argv[2]);

// Unix socket paths are short-bounded, so the runtime directory lives in /tmp.
function sandbox(t) {
  const root = mkdtempSync("/tmp/telar-help-");
  const directory = (name) => {
    const path = join(root, name);
    mkdirSync(path, { mode: 0o700 });
    return path;
  };
  const runtime = directory("run");
  const env = {
    HOME: directory("home"),
    XDG_RUNTIME_DIR: runtime,
    XDG_CONFIG_HOME: directory("config"),
    XDG_DATA_HOME: directory("data"),
    XDG_STATE_HOME: directory("state"),
    PATH: "/usr/bin:/bin",
    SHELL: "/bin/sh",
  };
  const cli = (args) => {
    const result = spawnSync(telar, args, { env, encoding: "utf8", timeout: 20_000 });
    if (result.error) throw result.error;
    return result;
  };
  t.after(() => {
    // Help must leave no runtime behind; stop one if a test ever started it.
    if (existsSync(join(runtime, "telar"))) cli(["server", "stop"]);
    rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
  });
  const untouched = () => assert.deepEqual(readdirSync(runtime), [], "help contacted or started a runtime");
  return { cli, untouched };
}

// The names under a heading of a help page: the first word of each indented line.
function listed(text, heading) {
  const start = text.indexOf(`\n${heading}\n`);
  assert.notEqual(start, -1, `${heading} is missing`);
  const names = [];
  for (const line of text.slice(start + heading.length + 2).split("\n")) {
    if (!line.startsWith("  ")) break;
    names.push(line.trim().split(/\s+/)[0]);
  }
  return names;
}

test("an agent walks from the root help to every command's help without knowing any name", (t) => {
  const { cli, untouched } = sandbox(t);
  const root = cli(["--help"]);
  assert.equal(root.status, 0, root.stderr);
  assert.match(root.stdout, /^telar \S+: /);
  assert.match(root.stdout, /`telar FAMILY --help`/);
  assert.match(root.stdout, /`telar FAMILY COMMAND --help`/);

  const familiesStart = root.stdout.indexOf("\nFamilies:\n");
  assert.notEqual(familiesStart, -1);
  const families = [];
  for (const line of root.stdout.slice(familiesStart).split("\n")) {
    if (line.startsWith("  ")) families.push(line.trim().split(/\s+/)[0]);
    if (line.startsWith("Options before COMMAND")) break;
  }
  assert.ok(families.length >= 20, `only ${families.length} families listed`);
  assert.equal(new Set(families).size, families.length, "a family is listed twice");

  let commands = 0;
  for (const family of families) {
    const page = cli([family, "--help"]);
    assert.equal(page.status, 0, `${family}: ${page.stderr}`);
    assert.ok(page.stdout.startsWith(`telar ${family}: `), `${family}: ${page.stdout.slice(0, 40)}`);
    assert.ok(page.stdout.includes(`\nUsage: telar ${family}`), `${family} has no usage`);
    if (!page.stdout.includes("\nCommands:\n")) continue;
    for (const command of listed(page.stdout, "Commands:")) {
      const detail = cli([family, command, "--help"]);
      assert.equal(detail.status, 0, `${family} ${command}: ${detail.stderr}`);
      assert.ok(detail.stdout.startsWith(`telar ${family} ${command}: `), `${family} ${command}: ${detail.stdout.slice(0, 60)}`);
      assert.ok(detail.stdout.includes(`\nUsage: telar ${family} ${command}`), `${family} ${command} has no usage`);
      const short = cli([family, command, "-h"]);
      assert.equal(short.stdout, detail.stdout, `${family} ${command}: -h differs from --help`);
      commands += 1;
    }
  }
  assert.ok(commands >= 100, `only ${commands} commands discovered`);
  untouched();
});

test("help reads the same wherever the flag sits, including nested words and a window's --client", (t) => {
  const { cli, untouched } = sandbox(t);
  const plain = cli(["pane", "split", "--help"]).stdout;
  assert.equal(cli(["pane", "split", "4", "horizontal", "--client", "1", "--help"]).stdout, plain);
  assert.equal(cli(["proxy", "trust", "install", "--help"]).stdout, cli(["proxy", "trust", "--help"]).stdout);
  assert.equal(cli(["client", "open", "goto", "--help"]).stdout, cli(["client", "open", "--help"]).stdout);
  assert.equal(cli(["exec", "--cwd", "/tmp", "--help"]).stdout, cli(["exec", "--help"]).stdout);
  assert.ok(cli(["workspace-list", "--help"]).stdout.startsWith("telar workspace-list: "));
  untouched();
});

test("an unknown or incomplete command line answers with the help to read", (t) => {
  const { cli, untouched } = sandbox(t);
  const unknown = cli(["worktree", "frobnicate"]);
  assert.equal(unknown.status, 1);
  assert.equal(unknown.stdout, "");
  assert.ok(unknown.stderr.includes("see `telar worktree --help`"), unknown.stderr);

  const incomplete = cli(["worktree", "create"]);
  assert.equal(incomplete.status, 1);
  assert.ok(incomplete.stderr.includes("see `telar worktree create --help`"), incomplete.stderr);

  const window = cli(["sidebar", "wat"]);
  assert.equal(window.status, 1);
  assert.ok(window.stderr.includes("see `telar sidebar --help`"), window.stderr);
  untouched();
});

test("a --help after -- belongs to the child and is never telar's help", (t) => {
  const { cli, untouched } = sandbox(t);
  // The directory is checked before anything connects, so the command fails
  // on it instead of printing help or starting a runtime.
  const create = cli(["workspace", "create", "--directory", "/nonexistent/telar-help-test", "--", "sh", "--help"]);
  assert.equal(create.status, 1);
  assert.ok(!create.stdout.includes("Usage:"), create.stdout);
  untouched();
});

test("the bundled skills print offline and point at the help", (t) => {
  const { cli, untouched } = sandbox(t);
  const general = cli(["--skill"]);
  assert.equal(general.status, 0, general.stderr);
  assert.ok(general.stdout.includes("telar FAMILY COMMAND --help"));
  assert.ok(!general.stdout.startsWith("---"), "the printed skill carries no front matter");
  const coordinator = cli(["--skill", "coordinator"]);
  assert.equal(coordinator.status, 0, coordinator.stderr);
  assert.ok(coordinator.stdout.includes("worktree create"));
  untouched();
});
