# Machine setup

`telar machine setup LABEL|DESTINATION` makes a machine this account reaches
over SSH ready for the window in one command: batch-mode SSH, this exact
build of telar at a path its profile saves, the person's agents installed,
integrated, configured and logged in, and a check that a window can attach.
The same command installs, updates to this client's build and repairs; on a
machine already set up it changes nothing and says so. `telar machine add
LABEL DESTINATION --setup` saves and sets up in one step. The design and its
decisions are in [the plan](../plans/machine-setup.md).

Credentials never leave this machine. Setup reads no key, token, auth file
or Keychain; each machine gets its own login through each agent's official
flow, revocable on its own.

## End-to-end path

```text
telar machine setup box [--label L] [--binary PATH] [--skip agents,config,login] [--confirm] [--json]
        |
MachineOptions.parse -> machine_profiles.run -> machine_setup.run
        |   resolve: a saved label or destination, or a new destination
        |   whose label is --label or its host, refused when another
        |   profile has that label; --confirm: a yes on the terminal first,
        |   without a terminal (or with --json) exit 1 and change nothing
        |
 1-2 reach: remote_shell.runScript(MachinePlatform.probe_script)
        |     ssh -T <SshOptions> DEST 'exec /bin/sh -s', the script on stdin;
        |     refused host key or login + a terminal: confirmInteractively,
        |     `ssh -o ControlPath=none DEST true` with the person's terminal,
        |     then batch mode again; still refused: stop, name ssh-copy-id
        |     MachinePlatform.parse: os, arch, libc, home, target path, the
        |     telar there, tools, node, agents
 3   installTelar
        |     ~/.local/share/telar/versions/VERSION[-SHA12]/telar prints
        |     this version: ok. Otherwise this build's install.sh runs there:
        |       release: telar_release.fetchDigest (SHA256SUMS here, curl
        |       --proto =https,file) -> install.sh --version --sha256 --headless
        |       --bin-dir; the machine downloads and both hashes must match
        |       --binary: upload (`cat >` over the same connection) ->
        |       install.sh --binary --sha256
 4   startRuntime: remote.discover through the saved path
        |     another build's runtime: with a terminal, ask; `y` runs
        |     `server stop` with the telar that started it, then waits;
        |     otherwise the step fails and setup stops
        |   linkCommand: `TARGET cli install --dir ~/.local/bin`, only now
 5   saveProfile: machine_profiles.storeAll, one locked change:
        |     add, place_telar (telar_path), enable (not after add --disabled)
 6   agent_setup.install: agents on this PATH missing there, each with its
        |     official installer, downloaded over https into a file first;
        |     a missing prerequisite is a note
 7   agent_setup.integrate: `TARGET integration install AGENT` there
 8   config_sync.run: allowlisted files, filtered here, written there by
        |     `TARGET machine receive-config` (config_receive) when they differ;
        |     a file with an inline secret (config_secrets) stays here
 9   agent_login.run: per agent not logged in there, its official login in a
        |     workspace of that runtime (`workspace create --columns 1024 --`),
        |     or the one an earlier setup left waiting (its record in
        |     ~/.local/state/telar/setup-logins there), the link read with
        |     `pane read --json` and taken only on an allowed host, a notification
        |     here whose click opens it, a pasted code typed with `pane
        |     send-keys --stdin`, the agent's status command polled, the
        |     process exit checked before and after the link, the owned tab
        |     closed if still present when the login ends; each outcome saved
        |     as `logins`
10   check: remote.discover again, schemas equal
        |
SetupReport: one numbered line per step as it ends, or one JSON object
```

## Rules

- **The login shell parses one constant.** Every remote step runs `exec
  /bin/sh -s` with its script on standard input; values are `/bin/sh`
  single-quoted assignments at its top (`remote_shell.assign`). The upload
  runs a constant `/bin/sh -c '…'` whose only variable part is hex.
- **Telar never accepts a host key and never copies a key.** The one
  interactive `ssh` leaves every answer to OpenSSH and the person, uses no
  control master, and setup still requires batch mode afterwards.
- **The client names the archive.** The machine downloads the release, but
  `install.sh` refuses it unless it hashes to what this machine read from its
  own release's `SHA256SUMS`, besides the machine's own copy. The machine runs
  the installer embedded in this build, never one it downloaded.
- **Versions sit side by side.** An update never replaces the executable a
  running runtime uses; the profile's `telar_path` moves to the new one and
  windows reconnect through it ([machine profiles](machine-profiles.md)).
- **A runtime is stopped only when the person agrees**, on a terminal.
- **Nothing runs with sudo.** A prerequisite an agent's installer lacks
  (Node for Pi, Alpine packages for Claude Code, glibc for Cursor) is
  reported, and the next setup installs the agent once it is there.
- **The sync is an allowlist** (`config_allowlist`): named files and
  directories per agent, hidden entries skipped, a denylist of credential
  names, name fragments, extensions and directories applied to every path
  and every symlink target. Each agent's root is resolved once (it may be a
  symlink into a dotfiles checkout); every file and directory below it must
  resolve inside it, and a hard-linked file is refused, so no link reaches
  a file elsewhere. Secret keys, MCP servers and credential helpers are
  dropped (`config_filter`, TOML by dotted path, multi-line values
  included), hooks keep only commands whose programs exist there, this
  home's paths become the machine's, and telar's own hooks are written for
  the machine's telar. Then every file is scanned for inline secrets
  (`config_secrets`); a file with one stays here and the report names its
  line and shape, never the value. The scan is a heuristic and misses a
  secret with no recognizable shape. The machine writes only under the
  agents' directories, never through a symlink, and only what differs,
  overwriting an edit made there by hand: the machine's copy follows this
  one.
- **Logins are the agents' own.** Setup reads a login's link and one-time
  code from its pane and shows them, but stores neither; what the person
  pastes is typed into the login pane and nowhere else. A provider with no
  browser login (OpenCode with Anthropic) is left to the person.
- **A login link names an allowed host.** Each agent's login has a list of
  the hosts its link may name (`agent_login.planFor`, sources in the plan's
  Agent facts); setup takes the first link in the pane on one of them with
  no user info or port, and passes over any other link something printed
  there. The notification it sends goes to the local runtime, and its card
  shows the host before the click ([notifications](../notifications.md)).
- **Login records name owned panes.** Setup checks the workspace id and
  login name before querying the recorded tab, then checks its pane id.
  Missing or mismatched state drops the record without closing another
  pane. Cleanup rechecks ownership and tolerates an exact missing-tab
  refusal if the child exited during cleanup; SSH, status and protocol
  failures still fail the login step.
- **A terminated login is no longer pending.** Structured pane reads expose
  its exit code, including after the runtime collected the pane. Setup
  checks the agent's official status when the process ends: a natural exit
  succeeds only when authentication is confirmed. A failed exit reports
  its code once and continues to the next agent. Pane text is not copied
  into report notes because it may contain an OAuth link or device code.

## Failures

A step that fails stops what depends on it: no SSH, no telar, no runtime
means no profile change. SSH failing inside a step (ssh not starting, a
timeout, exit 255) fails that step and no other, and the report always
comes. How much a script prints never fails it: `remote_shell` keeps the
newest 256 KiB of its output and 64 KiB of its errors, so an installer's
warnings cannot turn its success into a failure. A step that parses what a
script printed (the probe, the paths a sync asks about, a login record)
reads it through `ScriptOutput.wholeStdout`, which refuses output whose
start was dropped and names `machines.remote_shell_stdout_bytes`, so a cut
path or a hook that seems missing is never taken as the answer; a status check or a question about the
machine that SSH did not answer is never read as a "no". A login that is
still waiting is `pending`, not a failure, and the machine is reported as
waiting for it, not ready; the next setup reports it done. The exit status
is 1 when any step failed.

## Validation

- `python3 tools/test_machine_setup.py` after `zig build`, in CI on macOS
  and Linux: the whole of `run` against a machine simulated here by a fake
  `ssh`, with SSH failures injected per step, idempotence, the refusals and
  a person's workspace named like a login.
- Unit tests: `remote_telar`, `MachineProfile(s)` (path, logins, version,
  the worst case within the bound; `zig build test-machine-profiles`),
  `notification_link`, `config_secrets`, `remote_shell`
  (quoting through `/bin/sh`), `MachinePlatform`, `telar_release`,
  `SetupReport`, `agent_setup`, `config_allowlist` (every known credential
  denied, only agent directories accepted), `config_filter`, `config_receive`
  (symlinks, traversal, bounds), `config_sync` (no credential of any agent in
  the stream, however linked or written; hooks pruned), `agent_login`
  (links and codes from pane text, allowed hosts only), `agent_setup`
  (installers stop on a failed download),
  `MachineOptions`, `WorkspaceOptions`.
- `packaging/release/test-install.sh`: `--sha256` and `--binary`.
- `src/client_tests`: a notification's link opens through the link opener
  when clicked, and a remote runtime's notification loses its link.
  `src/gui/tests`: a card names its link's host; a machine that lacks this
  build is set up in a tab of this machine with `--confirm`, a `--remote`
  row by its destination. `src/headless`: links, sounds and desktop notices
  complete without running anything.
- Against Debian 12 and Alpine 3.22 containers without telar or agents, from
  a macOS client, with an isolated SSH configuration: see the plan's
  [Verification](../plans/machine-setup.md#verification).
