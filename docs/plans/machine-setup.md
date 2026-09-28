# Machine setup

Status: implemented on the `worktree-machine-setup` branch, audited and
corrected (see [Verification](#verification)); flow:
[machine setup](../flows/machine-setup.md). Differences from the plan below
are listed under [As built](#as-built). It builds on
[machine profiles](../flows/machine-profiles.md),
[remote attach](../flows/remote-attach.md),
[machine dispatch](../flows/machine-dispatch.md) and the
[machines plan](machines.md), whose Security section binds it.

## Problem

A machine becomes usable from the window only after four manual steps
([remote attach, SSH requirements](../flows/remote-attach.md#ssh-requirements)):
the same telar build on both sides, `telar` on the PATH of non-interactive
SSH sessions, key authentication and a verified host key. Agents are worse:
each one has to be installed, integrated with telar, configured like the
laptop and logged in, by hand, on every machine.

`telar machine setup` does all of that in one idempotent command:

```
telar machine setup LABEL|DESTINATION [--label LABEL] [--binary PATH]
                    [--skip agents,config,login] [--json]
telar machine add LABEL DESTINATION --setup [the same options]
```

The same command installs, updates to this client's exact build and
repairs. On a machine that is already set up it changes nothing and says so.

## Rules

- **Credentials never leave this machine.** Telar never reads, copies or
  sends a token, a key, an auth file or the Keychain. Each machine gets its
  own login through each agent's official flow, revocable on its own. The
  sync is an allowlist of files; everything else stays home
  ([What is synced](#what-is-synced)).
- **Telar never accepts a host key.** The first connection may be
  interactive because the person runs it from a terminal: OpenSSH asks, the
  person answers. Telar never passes `StrictHostKeyChecking=no` or
  `accept-new`.
- **Every later call is batch mode.** Setup requires the managed
  `BatchMode=yes` connection to work before it installs anything, and says
  how to fix it (`ssh-copy-id`) when it does not. It never copies a key.
- **Nothing runs with sudo.** telar and the agents install under the remote
  home.
- **A running runtime is never stopped silently.** Updating telar leaves the
  old runtime and its panes running on their old executable unless the
  person agrees to stop it ([decision 1](#decisions)).
- **No new trust.** Setup adds nothing beyond the SSH keys the person
  configured (machines plan, Security). No agent forwarding, no port
  forwarding, no inbound connection to this machine.

## Flow

```text
telar machine setup box
        |
 1. SSH access         ssh <managed options> box true           batch mode
        |                fails with a host key or login refusal and stdin
        |                is a terminal:
        |                  ssh -o ControlPath=none box true       interactive,
        |                  OpenSSH asks; then batch mode again.  Still refused:
        |                  stop, print `ssh-copy-id box`.
 2. Platform           probe script: uname -s, uname -m, $HOME, curl or wget,
        |                sha256sum or shasum, the installed telar, the agents
        |                Linux x86_64|aarch64 -> telar-linux-ARCH-headless.tar.gz
        |                macOS arm64|x86_64   -> telar-macos-ARCH.tar.gz
        |                anything else        -> error, nothing installed
 3. telar              ~/.local/share/telar/versions/VERSION/telar present and prints
        |                this version: unchanged. Otherwise install (below).
 4. Runtime            discovery through the absolute path: same schema, or
        |                none running: ok. Another build running: ask on the
        |                terminal whether to stop it; without a terminal or a
        |                yes, report it and stop: the profile and every later
        |                step need this build's runtime.
        |                Then ~/.local/bin/telar moves to this build.
 5. Profile            machines.json: add or update `telar_path`,
        |                enable. Under the file lock, like every change.
 6. Agents             for each agent installed here and missing there: its
        |                official installer, without sudo. A prerequisite the
        |                machine lacks (Node, ...) is reported, not improvised.
 7. Integrations       ABSOLUTE_PATH integration install AGENT, for each agent
        |                present there
 8. Configuration      allowlisted files, filtered here, written there only
        |                when they differ ([What is synced](#what-is-synced))
 9. Logins             per agent not logged in there: its official login in a
        |                pane of the remote runtime; the link reaches this
        |                window ([One click per login](#one-click-per-login))
10. Check              `telar machine check`: reachable, schema matches
```

Each step prints one numbered line with `changed`, `unchanged`, `skipped`
or `failed` and its detail. `--json` prints one object at the end with the
same steps. A failed step stops the steps that depend on it (no telar, no
integrations) and not the others (a failed login does not undo the sync).
The exit status is 0 only when every step that ran succeeded; a login that
is still pending when setup returns is `pending`, not a failure, and the
report says the machine waits for it (`"ready":false,"pending":true`). A
failure of SSH itself (ssh not starting, a timeout, exit 255, a script's
output past its bound) is a failure of the step it happened in, never of
setup as a whole: the report always comes.

Every remote step runs `exec /bin/sh -s` and sends its script on standard
input, so the login shell (sh, bash, zsh or fish) parses only that constant
command. Values the script needs are written at its top as `/bin/sh`
single-quoted assignments, so no login shell ever quotes them.

## Installing telar

One installer, `install.sh`, gains two options; setup embeds the
`install.sh` of its own build and sends it as the script, so the machine
runs the installer that matches the client, never one it downloaded:

| Option | Meaning |
| --- | --- |
| `--sha256 HEX` | the archive (or binary) must hash to this, checked besides `SHA256SUMS` |
| `--binary FILE` | install this telar executable instead of downloading a release |

A released build (`build.zig.zon` version other than `0.0.0`):

1. This machine downloads `SHA256SUMS` of its own version from
   `TELAR_RELEASES_URL` (default `https://github.com/adriangs1996/telar/releases`)
   with `curl --proto '=https,file'`, and reads the hash of the archive the
   machine needs.
2. The machine runs `install.sh --version V --headless --sha256 H --bin-dir
   ~/.local/share/telar/versions/V`: it downloads the archive itself, refuses it
   unless both hashes match, runs the staged binary from the target
   directory and renames it into place, as today.

A development build has nothing to download: setup refuses without
`--binary PATH`, a telar built for the machine (`zig build -Dgui=false
-Dtarget=aarch64-linux-musl`). Setup hashes it here, streams it over the
same SSH connection into a private file there, and runs `install.sh
--binary FILE --sha256 H`. The binary must print this client's `--version`
and discovery must report this client's schema; its directory is
`~/.local/share/telar/versions/VERSION-SHA12`, where `SHA12` is the first twelve hex
digits of its hash, so two development builds never share a path.

Versions live side by side. A runtime started by the old executable keeps
it. Old versions are never removed, for now: a later `telar machine prune`
will remove the versions no runtime runs (decided with Adrian on
2026-09-28). `~/.local/bin/telar` becomes a symlink to the new executable
through `telar cli install --dir ~/.local/bin` only once this build's
runtime runs there, so declining to stop the old runtime, or having no
terminal to ask on, leaves the command interactive shells find on the old
build. `cli install` refuses to replace anything but a symlink: a file
there stays, and setup says so.

## No more PATH

`machines.json` gains an optional field per machine:

```json
{"id":"m-3f9c2a00b001","label":"box","destination":"dev@box","enabled":true,
 "telar_path":"/home/dev/.local/share/telar/versions/0.3.0/telar"}
```

- `telar_path` is absolute, at most 255 bytes, and holds only ASCII letters,
  digits and `/._+-`: it goes into remote command lines unquoted, so no
  character any shell reads specially is allowed. A home that needs more
  keeps the PATH lookup, and setup says so.
- Discovery runs `/bin/sh -c '…; exec PATH server endpoint'`, the bridge
  `exec PATH server bridge`, dispatch `PATH dispatch-argv …`.
- A profile without the field works as today, through `telar` on the PATH.
- `RemoteMachine` gains `telar_path: ?[]const u8`; `Machines` gains a column; a
  changed path is a moved machine for `window_machines.reconcile`, so open
  windows reconnect through the new executable.
- The runtime the machine starts inherits that executable, so panes get it
  in `TELAR_BIN_PATH` and `integration install` writes it into hooks.

## Agents

Setup knows five agents. It detects on this machine which ones the person
has (the command on this PATH), and on the machine which ones are installed
(the official install locations and `command -v` in a login shell). Facts
per agent, each with its source, are in [Agent facts](#agent-facts).

## What is synced

The sync is an explicit allowlist of paths per agent, relative to the home
on both sides. Anything outside it is never read for sync.

Never synced, whatever the allowlist says: credential and token files, the
Keychain, session and history stores, caches, logs, databases, and any file
whose name or resolved target is in the credential denylist (the files of
[Agent facts](#agent-facts) marked secret, plus `~/.claude.json`, `~/.ssh`,
`~/.gnupg`, `~/.aws`, `~/.netrc`, `~/.npmrc`, `~/.pgpass`, `~/.vault-token`,
the GitHub CLI's `hosts.yml`, `keys.json`, `sa.json`, `*.pem`, `*.key`,
`.env*`, `*.env`, and any name holding `credential`, `secret`, `token`,
`password` or `passwd`), compared without case. Session stores are never
synced either, even when a hook names a file in one: `*.jsonl`, `*.db`,
`*.sqlite`, `*.sqlite3`, `*.log`, and anything under an agent's
`projects/`, `sessions/`, `history/`, `todos/`, `shell-snapshots/`,
`file-history/`, `statsig/`, `logs/`, `cache/` or `plans/`.

Symlinks never lead out of an agent's directory. The sync reads under one
root per agent (`~/.claude`, `~/.codex`, …, and `~/.agents/skills`), and
resolves each root's real path once, so a root that is itself a symlink
into a dotfiles checkout (`~/.claude -> ~/dotfiles/claude`) is followed.
Every file and directory below it must resolve inside that real
directory: a symlink below the root that leads anywhere else
(`skills/notes.json -> ~/.claude.json`, `skills/x -> ~`, or a file linked
into the dotfiles checkout from outside the root's directory there) is
skipped and reported. A file with more than one hard link is skipped too,
since its other name could be any file. Depth is bounded, so a cycle ends.

Secrets written inline are held back. After filtering, every file's bytes
are scanned (`config_secrets`) for the shapes secrets are written in: an
assignment or header whose name says secret (`TOKEN=…`, `x-api-key: …`,
`Cookie: …`, `AUTH_HEADER=Basic …`, `PUSHOVER_APP=…`, names ending in
`_KEY`, `_HEADER` or `_APP`, `GITHUB_PERSONAL_ACCESS_TOKEN: …` in a
subagent's frontmatter), `Bearer` tokens, a password inside a URL or on a
command line (`curl -u user:password`, `mysql -ppassword`), webhook URLs
whose path is their key (Slack, Discord, Teams, Zapier, Telegram, Google
Chat, ntfy.sh topics), the prefixes of well-known tokens (`ghp_`,
`github_pat_`, `sk-`, `xoxb-`, `AKIA`, `hf_`, `r8_`, `tvly-`, …) and private
key blocks. A file with a finding stays here, whole, and the report
names it with the line and the shape, never the value, so the person can
move the secret into a variable (`TOKEN=$(…)`, `$TOKEN`), which the scan
leaves alone, and sync again. A settings file whose hook holds a secret is
held back whole, not rewritten. The scan is a heuristic: a secret with none
of these shapes, a bare random string under an innocent name, is not
recognized. The allowlist, the denylist and the key filter are the rules;
the scan is the net under them.

The machine's copy follows this one. The machine is changed only through
telar, so a synced file that differs there is overwritten, and an edit made
there by hand is lost at the next setup.

Bounds: 1 MiB per file, 16 MiB and 4,096 files per machine.

Transformations, all made here before anything is sent:

- Local home paths inside text files become the machine's home.
- Telar's own hooks and plugin files are dropped and written again with the
  machine's executable, the same bytes `integration install` would write
  there, so the second run finds nothing to change.
- JSON settings lose the keys that carry secrets or run local programs:
  see [decision 2](#decisions).
- A settings value naming a file inside the agent's directory (a status
  line script) brings that file along, under the same rules.

The machine receives the files through `PATH machine receive-config`, a
hidden command like `dispatch-argv`: a bounded framed stream on standard
input, each file written atomically and only when its bytes differ, never
through a symlink there, never outside the allowlisted directories. It
answers with one line per file: written, unchanged or refused.

## One click per login

For each agent that is not logged in there:

1. Setup creates a workspace on the machine's runtime running the agent's
   official login command (`telar --machine box workspace create --name
   "Log in to Codex" -- codex login --device-auth`). `workspace create`
   gains `-- COMMAND`, a CLI change; the wire message already carries a
   launch.
2. It reads that pane (`pane read`) until a URL appears, at most 60 s.
   `pane read` keeps soft wraps as line breaks, so the workspace is
   created 1,024 columns wide, wider than any login URL; nobody is attached
   to it yet to narrow it.
3. It shows a notification in this machine's window, "Log in to Codex on
   box", whose click opens the URL in the local browser: see
   [decision 3](#decisions). The URL is also printed in setup's
   output, where a telar pane makes it clickable.
4. A login that wants something pasted back (Claude Code's code, Pi's
   redirect URL) asks for it in setup's own terminal and types it into the
   login pane with `pane send-keys`, so the person never looks for that
   pane. Device-code logins need nothing more than the browser.
5. It polls the agent's official status command there until it reports a
   login (at most 15 minutes, Codex's device-code lifetime), then marks
   the login done and closes the workspace.

The URL and the pasted text are never stored or logged; a code pasted back
is a one-time code, typed into the agent that asked for it and nowhere else.

The pane itself is a fallback: its URL is clickable in the window like any
other ([link opening](../flows/link-opening.md)).

Login states are `pending`, `done` and `failed`. They are printed by setup
and kept per machine in `machines.json` as `logins`, which `machine list`
shows. They are what setup last saw, not a live fact, so the window does
not show them beside the live state of each machine's link.

A login that ends, done or failed, closes its tab there. One still waiting
when setup returns (no terminal to wait on) keeps its pane; the next setup
shows its link again instead of opening another, and closes it once the
agent reports the login done. Setup knows its login panes by a record only
it writes on the machine, `~/.local/state/telar/setup-logins/AGENT` holding
`WORKSPACE TAB PANE`, and takes a pane only while that pane is still in a
workspace with the login's name; a workspace a person named "Log in to
Codex" is never reused or closed. What the person pastes
travels on standard input (`pane send-keys ID --stdin`), never in an argv
here or there.

## The window

A machine whose link failed with `RemoteTelarMissing`,
`RemoteTelarIncompatible` or `RemoteRuntimeIncompatible` gets a row
action "Set up telar on this machine". It opens a tab on this machine that
runs `TELAR machine setup LABEL --confirm`, so one key press in the list
installs nothing: setup says what it will do and waits for a yes on the
tab's terminal (without a terminal, or with `--json`, it changes nothing
and exits 1, as one JSON object with `refused` under `--json`), then the person sees each step and can answer OpenSSH if it
asks. A row `--remote` opened has no profile and a label cut from its
destination, so setup gets the destination.

## Agent facts

Checked on 2026-09-28. Installers were read as text; none was run on a
real account. Cursor's CLI is closed source: its facts come from the
public Linux x64 package `2026.09.26-dd393fe`, marked (bundle).

| Agent | Install without sudo | Where it lands | Needs |
| --- | --- | --- | --- |
| Claude Code | `curl -fsSL https://claude.ai/install.sh \| bash` ([setup](https://code.claude.com/docs/en/setup)) | `~/.local/bin/claude` → `~/.local/share/claude/versions/` | bash, curl; Alpine also `libgcc libstdc++ ripgrep` from apk, which needs root |
| Codex | `curl -fsSL https://chatgpt.com/codex/install.sh \| CODEX_NON_INTERACTIVE=1 sh` ([env vars](https://learn.chatgpt.com/docs/config-file/environment-variables.md)) | `~/.local/bin/codex` | curl or wget, tar; musl build on every Linux |
| Pi | `curl -fsSL https://pi.dev/install.sh \| sh` ([quickstart](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/quickstart.md)) | `~/.pi/agent/install`, link in the first writable of `~/.local/bin`… | Node 22.19+; without it the installer wants sudo or a tty, so setup reports it |
| OpenCode | `curl -fsSL https://opencode.ai/install \| bash -s -- --no-modify-path` (installer source) | `~/.opencode/bin/opencode` | tar; detects musl |
| Cursor Agent | `curl https://cursor.com/install -fsS \| bash` ([installation](https://cursor.com/docs/cli/installation.md)) | `~/.local/bin/agent`, `cursor-agent` | its bundled `node` is glibc (bundle): refused on Alpine |

Setup runs each installer from the URL above, but never through a pipe:
`curl --proto '=https' --tlsv1.2 -fsSL URL -o FILE` into a private
temporary file under `set -eu`, then the shell on that file with no
standard input. A download that fails fails the install, where `curl … |
sh` handed the shell an empty script that exited 0.

Logins from a machine without a browser, and how setup knows they are done:

| Agent | Official login | What the person does | Done when |
| --- | --- | --- | --- |
| Claude Code | `claude auth login` prints a URL; the browser shows a code to paste back ([troubleshooting](https://code.claude.com/docs/en/troubleshoot-install)) | open the link, copy the code | `claude auth status` exits 0 ([CLI reference](https://code.claude.com/docs/en/cli-reference)) |
| Codex | `codex login --device-auth`, device code, polls up to 15 min ([auth](https://learn.chatgpt.com/docs/auth.md), `codex-rs/login/src/device_code_auth.rs`); device login must be enabled in ChatGPT's security settings | open the link, type the code | `codex login status` exits 0 (`codex-rs/cli/src/login.rs`) |
| Pi | no CLI command: `/login` in the TUI; Anthropic asks to paste the redirect URL, OpenAI offers a device code ([providers](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md)) | pick the provider, open the link, paste or type | `pi auth check --provider P` exits 0 ([cli](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md)) |
| OpenCode | `opencode auth login -p PROVIDER -m METHOD`; OpenAI has a device flow `"ChatGPT Pro/Plus (headless)"` (source); Anthropic is API key only ([providers](https://opencode.ai/docs/providers)) | open the link, type the code | `opencode auth list` lists the provider; it has no exit status for it |
| Cursor Agent | `NO_OPEN_BROWSER=1 agent login` prints the URL and polls ([authentication](https://cursor.com/docs/cli/reference/authentication.md), bundle) | open the link | `agent status --format json` says `authenticated` (it exits 0 either way, bundle) |

Hosts a login link may name, checked on 2026-09-28; setup shows no link
to any other host ([decision 3](#decisions)). No vendor's documentation
names them, so they come from source or the shipped build:

| Agent | Hosts | Source |
| --- | --- | --- |
| Claude Code | `claude.com`, `platform.claude.com`, `claude.ai` | 2.1.284 binary: `CLAUDE_AI_AUTHORIZE_URL:"https://claude.com/cai/oauth/authorize"`, `CONSOLE_AUTHORIZE_URL:"https://platform.claude.com/oauth/authorize"`; `claude.ai/oauth/authorize` is Pi's Anthropic login (`packages/ai/src/auth/oauth/anthropic.ts`) |
| Codex | `auth.openai.com` | `codex-rs/login/src/server.rs`: `DEFAULT_ISSUER: &str = "https://auth.openai.com"`; `device_code_auth.rs`: `format!("{base_url}/codex/device")` |
| OpenCode (OpenAI) | `auth.openai.com` | `packages/opencode/src/plugin/openai/codex.ts`: `const ISSUER = "https://auth.openai.com"` |
| Cursor Agent | `cursor.com` | bundle `index.js`: `new URL("/loginDeepControl", t)` with `"https://cursor.com"` |

Each can be moved by the agent's own override (`CLAUDE_CODE_CUSTOM_OAUTH_URL`,
Codex's `--experimental_issuer`, `CURSOR_WEBSITE_URL`); a login moved that
way shows no link, and the person opens it from the pane.

Secret files, never read or sent (the denylist starts with these):
`~/.claude/.credentials.json`, `~/.claude.json` (OAuth session, MCP servers,
project history), `~/.codex/auth.json`, `~/.codex/.credentials.json` (MCP
OAuth), `~/.pi/agent/auth.json`, `~/.pi/agent/models.json` (may hold keys),
`~/.local/share/opencode/auth.json`, `~/.local/share/opencode/mcp-auth.json`,
`~/.config/cursor/auth.json` and `mcp-auth.json` (bundle).

The allowlist (paths under each agent's directory; `CLAUDE_CONFIG_DIR`,
`CODEX_HOME`, `PI_CODING_AGENT_DIR`, `XDG_CONFIG_HOME` and
`CURSOR_CONFIG_DIR` move them on either side):

| Agent | Synced |
| --- | --- |
| Claude Code | `settings.json` (filtered), `CLAUDE.md`, `rules/`, `skills/`, `commands/`, `agents/`, `output-styles/`, `keybindings.json`, `themes/` |
| Codex | `config.toml` (filtered), `AGENTS.md`, `AGENTS.override.md`, `rules/`, `prompts/`, `~/.agents/skills/` |
| Pi | `settings.json` (filtered), `keybindings.json`, `AGENTS.md`, `SYSTEM.md`, `APPEND_SYSTEM.md`, `skills/`, `prompts/`, `themes/`, `extensions/` except telar's |
| OpenCode | `opencode.json(c)` (filtered), `tui.json`, `AGENTS.md`, `agents/`, `commands/`, `modes/`, `skills/`, `themes/`, `plugins/` except telar's |
| Cursor Agent | `cli-config.json` without `authInfo`, `skills/`, `agents/` |

Sessions, transcripts, history, plans, caches, logs and databases of every
agent are outside the allowlist. Claude's `plugins/` (marketplaces) and
Cursor's User Rules (not on disk) are not synced.

Which provider Pi and OpenCode log into comes from their synced settings
(Pi's default provider, OpenCode's `model`). A provider with no browser
login (OpenCode with Anthropic takes only an API key) is reported as a
manual step: setup never asks for or moves a key.

## Decisions

Settled with Adrian on 2026-09-28.

1. **A runtime of another build is running there.** The new telar cannot
   attach to it. With a terminal, setup asks whether to stop it (`telar
   server stop` there, which ends every pane of that runtime); without one,
   or when the answer is no, it leaves it running and reports that the
   machine will not connect until it stops.
2. **Hooks are synced, MCP is not.** Hooks travel with local home paths
   rewritten; a hook whose command starts with an absolute path that does
   not exist on the machine after the sync is omitted and reported. MCP
   configuration never travels (Claude keeps it in `~/.claude.json`, which
   is never sent; Codex `[mcp_servers.*]`, OpenCode `mcp`, Cursor
   `mcp.json`). `env`, `apiKeyHelper` and the other credential helpers are
   dropped. Each omitted key is reported by name. A key is dropped when its
   name holds `secret`, `password`, `passphrase`, `api_key`, `apikey`,
   `api-key`, `credential`, `bearer`, `private_key`, `authorization` or
   `cookie`, or `token` or `auth` unless its value is a number or a boolean
   (`max_tokens = 4096` and `requires_openai_auth = true` stay). Codex's
   `config.toml` is filtered line by line, since no TOML parser exists
   here: a table whose dotted path holds a dropped name goes whole
   (`[mcp_servers.*]`, `[projects.*]`, `[model_providers.x.http_headers]`,
   `[otel.exporter."otlp-http".headers]`), a key whose dotted path holds one
   goes with every line of its value (`http_headers.Authorization = …`, a
   `"""` string), and multi-line strings and arrays are followed so none of
   their lines is read as a key or a table.
3. **Notifications gain a link.** An optional `link` (https only, at most
   2 KiB) on `show_notification` and the notification event, opened through
   the existing link policy when the card is clicked, and `telar
   notification show --link URL`. The wire changes, so `schema_version`
   goes up. Any process that reaches a runtime can send one, so a link has
   a plain host (no user info, port or encoding), the card shows that host
   before the click, a window takes links only from this machine's runtime,
   and setup shows only a link to a host its agent's login is known to use.

## As built

- Versions live in `~/.local/share/telar/versions/`, not beside the history
  database in `~/.local/share/telar/`.
- The link on a notification is at most 1024 bytes, not 2 KiB: a runtime
  response slot holds it inline, and 1 KiB keeps the slot at the size another
  response already gives it (4,152 bytes, measured). Only the CLI sends a
  link; a client's own notification requests refuse one, so the client's
  outbox slots stay under 512 bytes.
- `pane read` keeps soft wraps, so the login workspace is created 1024
  columns wide (`workspace create --columns`) instead of changing the wire.
- A login pane closes itself when the login command exits.
- Pi has no command-line login: setup opens `pi`, types `/login` and leaves
  the provider choice to the person in that pane; its notification carries
  no link.
- The headless client gained `notification activate`, which clicks the
  newest notification, for end-to-end tests.
- `machines.json` says version 2 when a profile holds `telar_path` or
  `logins`, and 1 otherwise, so a person who never ran setup keeps a file
  every earlier build reads. Sixteen profiles at every field's longest take
  16,381 bytes; the bound doubles to 32 KiB to leave the next field room.
- A new destination whose label (derived or `--label`) another profile has
  is refused before anything is installed; the logins run only on the
  profile whose destination is the one set up.
- `machine add --disabled --setup` keeps the machine disabled; with
  `--setup`, `--check` adds no second check or JSON object.
- `telar-headless --remote DESTINATION` runs the telar a saved profile for
  that destination names, as a window does, and never opens a link, plays a
  sound or posts a desktop notice: it records them in its trace.
- A notification's link has a plain host (no user info, port,
  percent-encoding or backslash); the card names it before the click; a
  window drops the link of a notification from a remote machine's runtime;
  setup shows only a link to a host its agent's login is known to use
  ([Agent facts](#agent-facts)).

### Changes users see outside setup

For the release notes, since two of them change what existing commands do:

- A notification from a remote machine's runtime arrives without its link:
  the card shows it with no action, and only this machine's runtime can
  put a link one click away ([notifications](../notifications.md)). A
  runtime reached through a socket forwarded by hand looks local and keeps
  its links.
- `telar-headless` no longer opens links, plays sounds or posts desktop
  notices: it records each in its trace as an `effect` entry and completes
  it ([headless client](../flows/headless-client.md)).
- `pane send-keys ID --stdin` and `tab_id` in `workspace create --json` are
  new; nothing that existed changed.

## Verification

Two audits reviewed the branch on 2026-09-28; every finding below was
reproduced against the audited code (commit `23e127c7`) before it was
fixed, and the same test shows the fix.

- Unit tests (`zig build test-cli`, `test-machine-profiles`, `test-wire`,
  `test-gui`, `test-client-integration`, `test-headless`): the auditor's
  symlinks (`skills/notes.json -> ~/.claude.json`, `skills/x -> ~`, links
  to `gh`'s `hosts.yml`, `~/.cargo/credentials.toml`, `~/.vault-token`,
  `~/.pgpass`, a hard link to `~/.claude.json`, a root linked into a
  dotfiles checkout), the TOML shapes (`[model_providers.x.http_headers]`,
  `[otel.exporter."otlp-http".headers]`, `http_headers.Authorization`, a
  `"""` value), a hook posting to a Slack webhook, `TOKEN=… cmd` in a
  script and `GITHUB_TOKEN` in a subagent's frontmatter; none reaches the
  stream. On the audited code the symlinked `~/.claude.json` and the
  `Authorization` header were sent, a first file that was not JSON
  panicked with an integer overflow, `https://claude.ai@evil.com/` was
  taken as Claude's login link, and a card with a link and no target
  reached `unreachable`. A failed download made every installer exit 0
  through its pipe.
- `tools/test_machine_setup.py` (fake `ssh` running each command here as a
  separate machine): setup, nothing planted there, the login finished and a
  second run that changes nothing; one SSH failure at a time (exit 255 and
  output past 256 KiB, at the probe, `integration install`,
  `receive-config` and the login status) fails that step alone with the
  report printed; a taken label refused before installing; `add --disabled
  --check --setup --json` stays disabled with one object; `--confirm`
  without a terminal exits 1; a workspace a person named like a login is
  neither reused nor closed. CI runs it on macOS and Linux; it needs no
  network and no privileges (checked in a Linux container with
  `--network none` as an unprivileged user). On the audited
  binary five of these failed: no report after `RemoteOutputTooLong`, a
  failed status check read as a login to open with `ready:true`, the taken
  label accepted, two JSON objects.
- Containers (OrbStack, aarch64), each reached from macOS through an
  isolated `ssh -F` configuration with a test key and its host key scanned
  beforehand; fake `claude` and `codex` in the machine's `~/.local/bin`;
  `--binary` a `zig build -Dgui=false -Dtarget=aarch64-linux-musl` telar:
  - Debian 12 (`debian:bookworm-slim`, login shell bash) and Alpine 3.22
    (ash, musl detected): all ten steps, the configuration without any
    planted secret (`.claude.json` and the subagent with a token stayed
    here and were listed), Codex's login pending with its pane open; after
    the login, a second run reported every step `ok`, "was already set up;
    nothing changed", and the login's workspace was gone.
  - Debian 12 with `main`'s telar (another wire schema) running from a
    regular `~/.local/bin/telar`: without a terminal, and answering `n`,
    the runtime step failed, setup stopped and `~/.local/bin/telar` stayed
    the old build; answering `y` stopped the old runtime through that
    file, started this build's and finished, leaving the file in place
    with a note.
  - A fresh container whose host key was not yet in `known_hosts`: setup
    stopped at step 1 with "the host key … is not confirmed".
- Logins against real accounts were not run; Adrian runs them.

Open: the heuristic secret scan misses a secret with no recognizable shape
([What is synced](#what-is-synced)); old versions stay until `machine
prune` exists.

