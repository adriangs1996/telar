// Codex sessions in two panes of one directory, and a shared server started
// from one of them, against a built telar in a runtime of its own:
// `node hook_identity.test.mjs /path/to/telar`.
//
// A fake `codex` stands in for `codex --no-daemon`: it runs its hooks as its
// own children, so they descend from its pane. A fake server stands in for
// `codex app-server --managed-daemon`: started from pane A, it leaves the pane
// and runs hooks for sessions of both panes with pane A's environment. Only
// the reports whose process descends from their pane may reach a card; each
// rename reaches its own card; a restart resumes each session in its pane with
// `--no-daemon`.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";

assert.ok(process.argv[2], "usage: node hook_identity.test.mjs /path/to/telar");
const telar = resolve(process.argv[2]);

const threads = {
  alpha: "019a0000-0000-7000-8000-00000000000a",
  beta: "019a0000-0000-7000-8000-00000000000b",
  server: "019a0000-0000-7000-8000-00000000000d",
};

// What `codex --no-daemon` does for the hooks: run them in its own process
// tree with its environment. The thread comes from `resume <id>` or, for a new
// session, from FAKE_CODEX_THREAD.
const fakeCodex = (log) => `#!${process.execPath}
import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
const args = process.argv.slice(2);
const words = args.filter((arg) => !arg.startsWith("-"));
const thread = words[0] === "resume" ? words[1] : process.env.FAKE_CODEX_THREAD;
appendFileSync(${JSON.stringify(log)}, JSON.stringify({ thread, args, pane: process.env.TELAR_PANE_ID }) + "\\n");
// Without --no-daemon the CLI hands the session to the shared server,
// which runs the hooks elsewhere, unless it has no server: a version before
// it, or one with the daemon turned off (FAKE_CODEX_NO_SERVER).
if (args.includes("--no-daemon") || process.env.FAKE_CODEX_NO_SERVER) {
  const hook = (payload) => spawnSync(${JSON.stringify(telar)}, ["hook", "codex"], { input: JSON.stringify({ session_id: thread, cwd: process.cwd(), ...payload }) });
  hook({ hook_event_name: "SessionStart", source: "startup" });
  hook({ hook_event_name: "UserPromptSubmit", prompt: "go" });
  hook({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "call-" + thread, tool_input: { command: "echo own-" + thread } });
  // A payload past the hook's input limit (FAKE_CODEX_OVERSIZED), whose
  // tool input arrives before the bulk.
  if (process.env.FAKE_CODEX_OVERSIZED) {
    hook({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "call-big", tool_input: { command: "echo oversized" }, tool_response: "x".repeat(17 * 1024 * 1024) });
  }
}
// The runtime inspects the foreground process when the pane draws; with
// FAKE_CODEX_WORKING the pane shows Codex's status clock over its composer.
let seconds = 0;
setInterval(() => {
  seconds += 1;
  process.stdout.write(process.env.FAKE_CODEX_WORKING ? "\\x1b[H\\x1b[2JWorking (" + seconds + "s)\\r\\n\\r\\n\\u203a Ask Codex to do anything" : ".");
}, 200);
`;

// What the shared server does: it outlives the shell that started it, in a
// session of its own, and runs every session's hooks with the environment it
// inherited from the pane it was started in.
const fakeServer = (trigger, done) => `#!${process.execPath}
import { existsSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
if (process.argv[2] !== "--serve") {
  spawn(process.execPath, [process.argv[1], "--serve"], { detached: true, stdio: "ignore" }).unref();
  process.exit(0);
}
const hook = (payload) => spawnSync(${JSON.stringify(telar)}, ["hook", "codex"], { input: JSON.stringify({ cwd: process.cwd(), ...payload }) });
// A run that fails before the trigger removes the directory; the server
// leaves with it, and after a minute in any case.
setTimeout(() => process.exit(0), 60_000).unref();
const wait = setInterval(() => {
  if (!existsSync(${JSON.stringify(dirname(trigger))})) process.exit(0);
  if (!existsSync(${JSON.stringify(trigger)})) return;
  clearInterval(wait);
  hook({ hook_event_name: "SessionStart", source: "startup", session_id: ${JSON.stringify(threads.server)} });
  hook({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "call-server", session_id: ${JSON.stringify(threads.beta)}, tool_input: { command: "echo server-leak" } });
  writeFileSync(${JSON.stringify(done)}, "");
}, 20);
`;

function sandbox(t) {
  const root = mkdtempSync(join(tmpdir(), "telar-hook-"));
  const directory = (name) => {
    const path = join(root, name);
    mkdirSync(path, { mode: 0o700 });
    return path;
  };
  const bin = directory("bin");
  const codexHome = directory("codex");
  const env = {
    HOME: directory("home"),
    XDG_RUNTIME_DIR: directory("run"),
    XDG_STATE_HOME: directory("state"),
    XDG_CONFIG_HOME: directory("config"),
    XDG_DATA_HOME: directory("data"),
    XDG_CACHE_HOME: directory("cache"),
    CODEX_HOME: codexHome,
    PATH: `${bin}:/usr/bin:/bin`,
    SHELL: "/bin/sh",
    TERM: "xterm-256color",
  };
  const work = directory("work");
  const log = join(root, "codex.log");
  const trigger = join(root, "server.go");
  const done = join(root, "server.done");
  writeFileSync(join(bin, "codex"), fakeCodex(log));
  writeFileSync(join(bin, "codex-server"), fakeServer(trigger, done));
  chmodSync(join(bin, "codex"), 0o755);
  chmodSync(join(bin, "codex-server"), 0o755);

  // telar's Codex hooks are installed, as `telar integration install codex`
  // leaves them.
  writeFileSync(join(codexHome, "hooks.json"), JSON.stringify({ hooks: { Stop: [{ hooks: [{ type: "command", command: `exec '${telar}' hook codex` }] }] } }));
  const database = new DatabaseSync(join(codexHome, "state_5.sqlite"));
  database.exec("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT)");
  for (const id of Object.values(threads)) database.prepare("INSERT INTO threads (id, name) VALUES (?, NULL)").run(id);

  const servers = [];
  const cli = (...args) => {
    const result = spawnSync(telar, args, { env, encoding: "utf8", timeout: 10_000 });
    if (result.error) throw result.error;
    return result;
  };
  const json = (...args) => {
    const result = cli(...args, "--json");
    assert.equal(result.status, 0, `${args.join(" ")}: ${result.stderr}`);
    return JSON.parse(result.stdout);
  };
  const start = async () => {
    servers.push(spawn(telar, ["server"], { env, stdio: "ignore" }));
    await until("the runtime listens", () => cli("runtime", "status").status === 0);
  };
  const stop = async () => {
    cli("server", "stop");
    const server = servers.at(-1);
    await until("the runtime exits", () => server.exitCode !== null || server.signalCode !== null);
  };

  t.after(() => {
    cli("server", "stop");
    for (const server of servers) server.kill("SIGKILL");
    database.close();
    rmSync(root, { recursive: true, force: true });
  });

  return {
    env,
    work,
    json,
    start,
    stop,
    rename: (thread, name) => database.prepare("UPDATE threads SET name = ? WHERE id = ?").run(name, thread),
    type: (pane, text) => assert.equal(cli("pane", "send-keys", String(pane), text, "--enter").status, 0),
    agents: () => json("agent", "list").agents,
    // The runtime writes its checkpoint shortly after a change; a stop
    // before then would restore an older one.
    checkpointed: (...sessions) => {
      const files = readdirSync(root, { recursive: true }).filter((path) => path.endsWith("session.ckpt"));
      return files.some((path) => {
        const bytes = readFileSync(join(root, path)).toString("latin1");
        return sessions.every((session) => bytes.includes(session));
      });
    },
    launches: () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line)) : []),
    fireServer: async () => {
      writeFileSync(trigger, "");
      await until("the server ran its hooks", () => existsSync(done));
    },
  };
}

async function until(what, predicate, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((settle) => setTimeout(settle, 50));
  }
  assert.fail(`timed out waiting until ${what}`);
}

const agentIn = (agents, pane) => agents.find((agent) => agent.pane_id === pane);

test("each Codex session reports to its own pane and a shared server reaches none", async (t) => {
  const s = sandbox(t);
  await s.start();

  const alpha = s.json("workspace", "create", "--directory", s.work).pane_id;
  const beta = s.json("tab", "create", "--background", "--workspace", "1").pane_id;
  // Both agents start at once, so their hooks connect together.
  s.type(alpha, "codex-server");
  s.type(alpha, `FAKE_CODEX_THREAD=${threads.alpha} codex --no-daemon`);
  s.type(beta, `FAKE_CODEX_THREAD=${threads.beta} codex --no-daemon`);
  await until("both panes run Codex and report their tool call", () => {
    const agents = s.agents();
    return [alpha, beta].every((pane) => agentIn(agents, pane)?.provider === "codex" && agentIn(agents, pane).last_event.includes("own-"));
  });

  await s.fireServer();
  // A report that got through would be applied before `agent list` answers:
  // the hook waits for the runtime's reply.
  const agents = s.agents();
  assert.equal(agentIn(agents, alpha).provider, "codex");
  assert.match(agentIn(agents, alpha).last_event, new RegExp(`own-${threads.alpha}`));
  assert.match(agentIn(agents, beta).last_event, new RegExp(`own-${threads.beta}`));

  s.rename(threads.server, "server thread");
  s.rename(threads.alpha, "alpha task");
  await until("alpha's card takes its name", () => agentIn(s.agents(), alpha).title === "alpha task");
  assert.notEqual(agentIn(s.agents(), beta).title, "alpha task");

  s.rename(threads.beta, "beta task");
  await until("beta's card takes its name", () => agentIn(s.agents(), beta).title === "beta task");
  assert.equal(agentIn(s.agents(), alpha).title, "alpha task");
  assert.ok(s.agents().every((agent) => agent.title !== "server thread"));

  await until("the checkpoint records both sessions", () => s.checkpointed(threads.alpha, threads.beta));
  await s.stop();
  const launched = s.launches().length;
  await s.start();
  await until("both sessions resume", () => s.launches().length >= launched + 2);
  const resumed = s.launches().slice(launched);
  assert.deepEqual(resumed.map((launch) => launch.thread).sort(), [threads.alpha, threads.beta]);
  for (const launch of resumed) {
    assert.deepEqual(launch.args, ["resume", "--no-daemon", launch.thread]);
  }
});

test("a Codex started without --no-daemon that works without hooks says so on its card", async (t) => {
  const s = sandbox(t);
  await s.start();

  const pane = s.json("workspace", "create", "--directory", s.work).pane_id;
  s.type(pane, `FAKE_CODEX_WORKING=1 FAKE_CODEX_THREAD=${threads.alpha} codex`);
  await until("the card explains the shared server", () => {
    const agent = agentIn(s.agents(), pane);
    return agent?.provider === "codex" && agent.last_event === "no hooks from this pane: if it runs on a shared server, start it with --no-daemon";
  }, 15_000);
});

test("a Codex whose hooks reach its pane without --no-daemon shows no note and resumes without the flag", async (t) => {
  const s = sandbox(t);
  await s.start();

  const pane = s.json("workspace", "create", "--directory", s.work).pane_id;
  s.type(pane, `FAKE_CODEX_NO_SERVER=1 FAKE_CODEX_THREAD=${threads.beta} codex`);
  await until("its hooks reach the card", () => agentIn(s.agents(), pane)?.last_event.includes(`own-${threads.beta}`));

  await until("the checkpoint records the session", () => s.checkpointed(threads.beta));
  await s.stop();
  const launched = s.launches().length;
  await s.start();
  await until("the session resumes", () => s.launches().length > launched);
  assert.deepEqual(s.launches()[launched].args, ["resume", threads.beta]);
});

test("a hook payload past the input limit still reports its event and names the limit", async (t) => {
  const s = sandbox(t);
  await s.start();

  const pane = s.json("workspace", "create", "--directory", s.work).pane_id;
  s.type(pane, `FAKE_CODEX_OVERSIZED=1 FAKE_CODEX_THREAD=${threads.alpha} codex --no-daemon`);
  await until("the oversized tool call reaches the card", () => agentIn(s.agents(), pane)?.last_event.includes("oversized"), 20_000);

  const entry = s.json("diagnostics", "limits").limits.find((limit) => limit.name === "hooks.max_input_bytes");
  assert.ok(entry, "the hook reported its input limit");
  assert.equal(entry.origin, "client");
  assert.equal(entry.value, 16 * 1024 * 1024);
  assert.ok(entry.requested > entry.value);
});
