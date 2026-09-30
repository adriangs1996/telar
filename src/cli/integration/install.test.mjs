// `telar integration install|uninstall|status` against a built telar, in a
// throwaway home: the Pi and OpenCode files, the agents' directory
// variables, and Claude Code hooks left where CLAUDE_CONFIG_DIR no longer
// reads them. `node install.test.mjs /path/to/telar`.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";

assert.ok(process.argv[2], "usage: node install.test.mjs /path/to/telar");
// Each run starts in its own directory, so a relative path would not resolve.
const telar = resolve(process.argv[2]);

const agents = [
  { agent: "pi", noun: "extension", marker: "// telar-integration: pi\n", path: (home) => join(home, ".pi/agent/extensions/telar.ts") },
  { agent: "opencode", noun: "plugin", marker: "// telar-integration: opencode\n", path: (home, config) => join(config, "opencode/plugins/telar.ts") },
];

// A home and configuration directory of its own for each test, removed after it.
function sandbox(t) {
  const root = mkdtempSync(join(tmpdir(), "telar-integration-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const home = join(root, "home");
  const config = join(root, "config");
  mkdirSync(home);
  const run = (...args) => {
    const result = spawnSync(telar, ["integration", ...args], {
      cwd: root,
      env: { HOME: home, XDG_CONFIG_HOME: config },
      encoding: "utf8",
    });
    if (result.error) throw result.error;
    return { code: result.status, signal: result.signal, stdout: result.stdout, stderr: result.stderr };
  };
  return { root, home, config, run };
}

for (const { agent, noun, marker, path } of agents) {
  test(`${agent}: install writes the ${noun} owner-only once, status follows it and uninstall removes it`, (t) => {
    const s = sandbox(t);
    const file = path(s.home, s.config);

    assert.deepEqual(s.run("status", agent), { code: 0, signal: null, stdout: `telar ${noun}: absent at ${file}\n`, stderr: "" });

    const installed = s.run("install", agent);
    assert.equal(installed.code, 0, installed.stderr);
    assert.equal(installed.stdout, `telar integration: ${agent} ${noun} installed at ${file}\n`);
    const source = readFileSync(file, "utf8");
    assert.ok(source.startsWith(marker));
    const executable = /^const TELAR = (".*");$/m.exec(source);
    assert.ok(executable, "the executable path is filled in");
    assert.ok(existsSync(JSON.parse(executable[1])));
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(dirname(file)), ["telar.ts"]);

    assert.equal(s.run("status", agent).stdout, `telar ${noun}: installed at ${file}\n`);
    assert.equal(s.run("install", agent).stdout, `telar integration: ${agent} ${noun} already present at ${file}\n`);

    // A file an older telar wrote is replaced.
    writeFileSync(file, marker + "// older\n");
    assert.equal(s.run("install", agent).stdout, `telar integration: ${agent} ${noun} updated at ${file}\n`);
    assert.equal(readFileSync(file, "utf8"), source);

    assert.equal(s.run("uninstall", agent).stdout, `telar integration: ${agent} ${noun} removed from ${file}\n`);
    assert.ok(!existsSync(file));
    assert.equal(s.run("uninstall", agent).stdout, `telar integration: ${agent} ${noun} not present at ${file}\n`);
  });

  test(`${agent}: a file telar did not write is reported and never replaced or removed`, (t) => {
    const s = sandbox(t);
    const file = path(s.home, s.config);
    mkdirSync(dirname(file), { recursive: true });
    const foreign = "export default function () {}\n";
    writeFileSync(file, foreign);

    assert.equal(s.run("status", agent).stdout, `telar ${noun}: foreign at ${file}\n`);

    const install = s.run("install", agent);
    assert.equal(install.code, 1);
    assert.equal(install.stderr, `telar integration: ${file} exists and is not telar's ${noun}; move it first\n`);

    const uninstall = s.run("uninstall", agent);
    assert.equal(uninstall.code, 1);
    assert.equal(uninstall.stderr, `telar integration: ${file} is not telar's ${noun}; left untouched\n`);
    assert.equal(readFileSync(file, "utf8"), foreign);
  });

  test(`${agent}: --settings takes an absolute path and refuses a relative one`, (t) => {
    const s = sandbox(t);
    const file = join(s.root, "elsewhere", "telar.ts");
    const installed = s.run("install", agent, "--settings", file);
    assert.equal(installed.code, 0, installed.stderr);
    assert.ok(readFileSync(file, "utf8").startsWith(marker));
    assert.equal(s.run("uninstall", agent, "--settings", file).code, 0);
    assert.ok(!existsSync(file));

    for (const action of ["install", "uninstall", "status"]) {
      const relative = s.run(action, agent, "--settings", "plugins/telar.ts");
      assert.equal(relative.signal, null, relative.stderr);
      assert.equal(relative.code, 1);
      assert.match(relative.stderr, /RelativeSettingsPath/);
    }
    assert.ok(!existsSync(join(s.root, "plugins")));
  });
}

test("opencode: without XDG_CONFIG_HOME the plugin goes to ~/.config/opencode/plugins", (t) => {
  const s = sandbox(t);
  const result = spawnSync(telar, ["integration", "install", "opencode"], { cwd: s.root, env: { HOME: s.home }, encoding: "utf8" });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  assert.ok(existsSync(join(s.home, ".config/opencode/plugins/telar.ts")));
});

test("pi: PI_CODING_AGENT_DIR moves the extension", (t) => {
  const s = sandbox(t);
  const directory = join(s.root, "pi-agent");
  const result = spawnSync(telar, ["integration", "install", "pi"], { cwd: s.root, env: { HOME: s.home, PI_CODING_AGENT_DIR: directory }, encoding: "utf8" });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  assert.ok(existsSync(join(directory, "extensions/telar.ts")));
  assert.ok(!existsSync(join(s.home, ".pi")));
});

test("claude: CLAUDE_CONFIG_DIR holds the hooks, and hooks left in ~/.claude are reported and removed", (t) => {
  const s = sandbox(t);
  const directory = join(s.root, "claude-config");
  const legacy = join(s.home, ".claude/settings.json");
  const run = (...args) => {
    const result = spawnSync(telar, ["integration", ...args], { cwd: s.root, env: { HOME: s.home, CLAUDE_CONFIG_DIR: directory }, encoding: "utf8" });
    if (result.error) throw result.error;
    return result;
  };

  // Hooks installed before telar followed CLAUDE_CONFIG_DIR.
  const before = spawnSync(telar, ["integration", "install", "claude"], { cwd: s.root, env: { HOME: s.home }, encoding: "utf8" });
  assert.equal(before.status, 0, before.stderr);
  assert.ok(readFileSync(legacy, "utf8").includes(" hook claude"));

  const installed = run("install", "claude");
  assert.equal(installed.status, 0, installed.stderr);
  assert.ok(readFileSync(join(directory, "settings.json"), "utf8").includes(" hook claude"));

  const status = run("status", "claude");
  assert.equal(status.status, 0, status.stderr);
  assert.match(status.stdout, /SessionStart: installed/);
  assert.ok(status.stdout.includes(`hooks remain in ${legacy}`));

  const uninstalled = run("uninstall", "claude");
  assert.equal(uninstalled.status, 0, uninstalled.stderr);
  assert.ok(uninstalled.stdout.includes(`hooks removed from ${legacy} too`));
  assert.ok(!readFileSync(join(directory, "settings.json"), "utf8").includes(" hook claude"));
  assert.ok(!readFileSync(legacy, "utf8").includes(" hook claude"));
  assert.ok(!run("status", "claude").stdout.includes("hooks remain"));
});
