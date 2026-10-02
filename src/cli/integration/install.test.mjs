// `telar integration install|uninstall|status` against a built telar, in a
// throwaway home: the Pi and OpenCode files, the agents' directory
// variables, and Claude Code hooks left where CLAUDE_CONFIG_DIR no longer
// reads them. `node install.test.mjs /path/to/telar`.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";

assert.ok(process.argv[2], "usage: node install.test.mjs /path/to/telar");
// Each run starts in its own directory, so a relative path would not resolve.
const telar = resolve(process.argv[2]);

const agents = [
  { agent: "pi", noun: "extension", marker: "// telar-integration: pi\n", path: (home) => join(home, ".pi/agent/extensions/telar.ts"), root: (home) => join(home, ".pi/agent") },
  { agent: "opencode", noun: "plugin", marker: "// telar-integration: opencode\n", path: (home, config) => join(config, "opencode/plugins/telar.ts"), root: (home, config) => join(config, "opencode") },
];

// The skills telar writes beside an integration, each marked by its front matter.
const skills = [
  { name: "telar", needle: "telar FAMILY COMMAND --help" },
  { name: "telar-coordinator", needle: "worktree create" },
];

function skillPath(root, name) {
  return join(root, "skills", name, "SKILL.md");
}

function expectSkills(root) {
  for (const { name, needle } of skills) {
    const source = readFileSync(skillPath(root, name), "utf8");
    assert.ok(source.startsWith(`---\nname: ${name}\n`), `${name}: front matter`);
    assert.ok(source.includes(`\n---\n<!-- telar-integration: skill ${name} -->\n`), `${name}: marker`);
    assert.ok(source.includes(needle), `${name}: body`);
  }
}

function expectNoSkills(root) {
  for (const { name } of skills) assert.ok(!existsSync(skillPath(root, name)), `${name} remains`);
}

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

for (const { agent, noun, marker, path, root } of agents) {
  test(`${agent}: install writes the ${noun} owner-only once, status follows it and uninstall removes it`, (t) => {
    const s = sandbox(t);
    const file = path(s.home, s.config);
    const skillsRoot = root(s.home, s.config);
    const skillLines = (state) => skills.map(({ name }) => `skill ${name}: ${state} at ${skillPath(skillsRoot, name)}\n`).join("");
    const written = skills.map(({ name }) => `telar integration: skill ${name} written to ${skillPath(skillsRoot, name)}\n`).join("");

    assert.deepEqual(s.run("status", agent), { code: 0, signal: null, stdout: `telar ${noun}: absent at ${file}\n` + skillLines("absent"), stderr: "" });

    const installed = s.run("install", agent);
    assert.equal(installed.code, 0, installed.stderr);
    assert.equal(installed.stdout, `telar integration: ${agent} ${noun} installed at ${file}\n` + written);
    expectSkills(skillsRoot);
    const source = readFileSync(file, "utf8");
    assert.ok(source.startsWith(marker));
    const executable = /^const TELAR = (".*");$/m.exec(source);
    assert.ok(executable, "the executable path is filled in");
    assert.ok(existsSync(JSON.parse(executable[1])));
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(dirname(file)), ["telar.ts"]);

    assert.equal(s.run("status", agent).stdout, `telar ${noun}: installed at ${file}\n` + skillLines("installed"));
    assert.equal(s.run("install", agent).stdout, `telar integration: ${agent} ${noun} already present at ${file}\n` + written);

    // A file an older telar wrote is replaced, and so is an older skill.
    writeFileSync(file, marker + "// older\n");
    writeFileSync(skillPath(skillsRoot, "telar"), "---\nname: telar\ndescription: older\n---\n<!-- telar-integration: skill telar -->\n# older\n");
    assert.equal(s.run("install", agent).stdout, `telar integration: ${agent} ${noun} updated at ${file}\n` + written);
    assert.equal(readFileSync(file, "utf8"), source);
    expectSkills(skillsRoot);

    assert.equal(s.run("uninstall", agent).stdout, `telar integration: ${agent} ${noun} removed from ${file}\n`);
    assert.ok(!existsSync(file));
    expectNoSkills(skillsRoot);
    assert.equal(s.run("uninstall", agent).stdout, `telar integration: ${agent} ${noun} not present at ${file}\n`);
  });

  test(`${agent}: a skill telar did not write is reported as foreign and never replaced or removed`, (t) => {
    const s = sandbox(t);
    const skillsRoot = root(s.home, s.config);
    const mine = skillPath(skillsRoot, "telar");
    mkdirSync(dirname(mine), { recursive: true });
    writeFileSync(mine, "---\nname: mine\n---\n");

    assert.ok(s.run("status", agent).stdout.includes(`skill telar: foreign at ${mine}\n`));
    const installed = s.run("install", agent);
    assert.equal(installed.code, 0, installed.stderr);
    assert.ok(readFileSync(skillPath(skillsRoot, "telar-coordinator"), "utf8").startsWith("---\nname: telar-coordinator\n"));
    // Install never replaces a file that is not telar's.
    assert.equal(readFileSync(mine, "utf8"), "---\nname: mine\n---\n");
    assert.equal(s.run("uninstall", agent).code, 0);
    assert.equal(readFileSync(mine, "utf8"), "---\nname: mine\n---\n");
    assert.ok(!existsSync(skillPath(skillsRoot, "telar-coordinator")));
  });

  test(`${agent}: a file telar did not write is reported and never replaced or removed`, (t) => {
    const s = sandbox(t);
    const file = path(s.home, s.config);
    mkdirSync(dirname(file), { recursive: true });
    const foreign = "export default function () {}\n";
    writeFileSync(file, foreign);

    assert.ok(s.run("status", agent).stdout.startsWith(`telar ${noun}: foreign at ${file}\n`));

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

test("claude: CLAUDE_CONFIG_DIR holds the hooks; hooks left in ~/.claude are reported and removed only on request", (t) => {
  const s = sandbox(t);
  const directory = join(s.root, "claude-config");
  const legacy = join(s.home, ".claude/settings.json");
  const run = (env, ...args) => {
    const result = spawnSync(telar, ["integration", ...args], { cwd: s.root, env: { HOME: s.home, ...env }, encoding: "utf8" });
    if (result.error) throw result.error;
    return result;
  };
  const withDirectory = (...args) => run({ CLAUDE_CONFIG_DIR: directory }, ...args);

  // Hooks installed before telar followed CLAUDE_CONFIG_DIR.
  assert.equal(run({}, "install", "claude").status, 0);
  assert.ok(readFileSync(legacy, "utf8").includes(" hook claude"));

  const installed = withDirectory("install", "claude");
  assert.equal(installed.status, 0, installed.stderr);
  assert.ok(readFileSync(join(directory, "settings.json"), "utf8").includes(" hook claude"));
  expectSkills(directory);
  assert.ok(installed.stdout.includes(`telar integration: skill telar written to ${skillPath(directory, "telar")}\n`));

  const status = withDirectory("status", "claude");
  assert.equal(status.status, 0, status.stderr);
  assert.match(status.stdout, /SessionStart: installed/);
  assert.ok(status.stdout.includes(`skill telar: installed at ${skillPath(directory, "telar")}\n`));
  assert.ok(status.stdout.includes(`skill telar-coordinator: installed at ${skillPath(directory, "telar-coordinator")}\n`));
  assert.ok(status.stdout.includes(`hooks remain in ${legacy}`));
  assert.ok(status.stdout.includes("`telar integration uninstall claude --legacy`"));

  // A shell without the variable still reads ~/.claude: uninstall leaves it.
  const uninstalled = withDirectory("uninstall", "claude");
  assert.equal(uninstalled.status, 0, uninstalled.stderr);
  assert.ok(!readFileSync(join(directory, "settings.json"), "utf8").includes(" hook claude"));
  assert.ok(readFileSync(legacy, "utf8").includes(" hook claude"));

  const legacyRemoved = withDirectory("uninstall", "claude", "--legacy");
  assert.equal(legacyRemoved.status, 0, legacyRemoved.stderr);
  assert.ok(!readFileSync(legacy, "utf8").includes(" hook claude"));
  expectNoSkills(join(s.home, ".claude"));
  expectNoSkills(directory);
  assert.ok(!withDirectory("status", "claude").stdout.includes("hooks remain"));
});

test("claude: a trailing slash or a symlink to ~/.claude names the same settings", (t) => {
  const s = sandbox(t);
  const run = (env, ...args) => {
    const result = spawnSync(telar, ["integration", ...args], { cwd: s.root, env: { HOME: s.home, ...env }, encoding: "utf8" });
    if (result.error) throw result.error;
    return result;
  };
  assert.equal(run({}, "install", "claude").status, 0);
  symlinkSync(join(s.home, ".claude"), join(s.root, "linked-claude"));

  for (const directory of [join(s.home, ".claude") + "/", join(s.root, "linked-claude")]) {
    const status = run({ CLAUDE_CONFIG_DIR: directory }, "status", "claude");
    assert.equal(status.status, 0, status.stderr);
    assert.ok(!status.stdout.includes("hooks remain"), status.stdout);
  }
});

test("claude: uninstall never removes a skill telar did not write, nor hooks the user keeps in telar's groups", (t) => {
  const s = sandbox(t);
  const settings = join(s.home, ".claude/settings.json");
  const skill = join(s.home, ".claude/skills/telar-coordinator/SKILL.md");
  mkdirSync(dirname(skill), { recursive: true });
  writeFileSync(skill, "---\nname: mine\n---\n");
  writeFileSync(settings, JSON.stringify({ hooks: { Stop: [{ matcher: "", hooks: [{ type: "command", command: "mine.sh" }] }] } }));

  // With nothing of telar's in it, --legacy from another directory leaves
  // the file and the skill alone.
  const legacy = spawnSync(telar, ["integration", "uninstall", "claude", "--legacy"], { cwd: s.root, env: { HOME: s.home, CLAUDE_CONFIG_DIR: join(s.root, "other") }, encoding: "utf8" });
  assert.equal(legacy.status, 0, legacy.stderr);
  assert.equal(readFileSync(skill, "utf8"), "---\nname: mine\n---\n");

  const uninstall = s.run("uninstall", "claude");
  assert.equal(uninstall.code, 0, uninstall.stderr);
  assert.equal(readFileSync(skill, "utf8"), "---\nname: mine\n---\n");
  assert.ok(readFileSync(settings, "utf8").includes("mine.sh"));
});

test("claude: a settings file that is a symlink is written through and keeps its mode", (t) => {
  const s = sandbox(t);
  const dotfiles = join(s.root, "dotfiles");
  mkdirSync(dotfiles);
  const real = join(dotfiles, "claude-settings.json");
  writeFileSync(real, JSON.stringify({ model: "opus" }));
  chmodSync(real, 0o644);
  mkdirSync(join(s.home, ".claude"));
  const settings = join(s.home, ".claude/settings.json");
  symlinkSync(real, settings);

  const installed = s.run("install", "claude");
  assert.equal(installed.code, 0, installed.stderr);
  assert.ok(lstatSync(settings).isSymbolicLink());
  assert.ok(readFileSync(real, "utf8").includes(" hook claude"));
  assert.equal(statSync(real).mode & 0o777, 0o644);
});
