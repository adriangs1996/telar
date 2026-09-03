# Lua configuration

Telar loads `$XDG_CONFIG_HOME/telar/config.lua`, or
`$HOME/.config/telar/config.lua` when `XDG_CONFIG_HOME` is unset. Use
`--config PATH` to select another file, `--no-config` to disable it, and
`telar config check [PATH] [--profile NAME]` to validate a generation without
starting a client or runtime. The check also parses enabled plugin packages and
resolves every static plugin action referenced by the keymap.

Configuration precedence is:

1. compiled defaults;
2. the base Lua table;
3. the selected `--profile` overlay;
4. explicit CLI options.

The file must return a table with `api_version = 2`. Unknown fields are errors.
The complete schema is demonstrated by [`examples/config.lua`](../examples/config.lua).

```lua
local telar = require("telar")

return telar.config({
  api_version = 2,
  client = {
    prefix = "ctrl+s",
    icons = "nerd-font",
    theme = telar.theme({
      base = "vesper",
      colors = { accent = "#ffc799" },
    }),
    sidebar = { visible = true, renderer = "automatic" },
    sound = { enabled = true, ready = true, needs_input = true },
    input = { escape_timeout_ms = 25, sequence_timeout_ms = 1000 },
    keybindings = {
      telar.bind({ "s" }, telar.action.toggle_sidebar()),
      telar.bind({ "alt+left" }, telar.action.resize_sidebar({ direction = "left" })),
      telar.bind({ "shift+left" }, telar.action.resize_pane({ direction = "left" })),
      telar.bind({ "z" }, telar.action.toggle_pane_fullscreen()),
      telar.bind_global({ "ctrl+shift+s" }, telar.action.detach()),
    },
  },
  runtime = {
    history = { path = "state/history.db" },
    graphics = { pane_mib = 64, global_mib = 256 },
    proxy = {
      enabled = false,
      ca_dir = "state/proxy",
      intercept_hosts = {
        "api.anthropic.com",
        "api.openai.com",
        "chatgpt.com",
      },
    },
    agent_descriptions = {
      command = {
        "codex", "exec", "--ephemeral", "--ignore-rules",
        "--skip-git-repo-check", "--model", "gpt-5.6-luna",
        "-c", 'model_reasoning_effort="low"', "-",
      },
      timeout_ms = 15000,
    },
    agents = {
      {
        name = "gemini",
        display_name = "Gemini CLI",
        icon = "G",
        process_names = { "gemini" },
        process_paths = { "/@google/gemini-cli/" },
        identity = { "gemini cli" },
        working = { "esc to cancel" },
        attachments = "ordered",
      },
      { name = "claude", working = { "brewing" } },
    },
  },
  plugins = {
    telar.plugin({ path = "plugins/sample", enabled = true }),
  },
  profiles = {
    remote = {
      client = { sidebar = { visible = false, renderer = "cells" } },
      runtime = { graphics = { pane_mib = 16, global_mib = 64 } },
    },
  },
})
```

`runtime.agent_descriptions` is an explicit privacy opt-in. When the first user
request starts model work, Telar sends that request through standard input to
the configured command and accepts one short line as the session title. The
command runs in parallel with the agent and is executed directly, without a
shell. It may contain 1 to 32
arguments and 4096 bytes in total; `timeout_ms` must be between 1000 and 60000.
Telar retains its local placeholder if the command is missing, busy, times out,
or returns invalid output.

The example above uses the installed Codex subscription with Luna at low
reasoning effort. A Claude Code subscription can be selected without changing
Telar:

```lua
agent_descriptions = {
  command = {
    "claude", "--print", "--model", "haiku", "--effort", "low",
    "--tools", "", "--no-session-persistence",
  },
  timeout_ms = 15000,
}
```

`runtime.engine` keeps one headless agent process alive between prompts
instead of starting a command per request. It speaks Pi's RPC contract (JSON
lines over stdin and stdout) and is independent from `agent_descriptions`:
session titles always use the one-shot command, and the engine only serves
the features that name it below. The child starts on the first prompt from
`/`, never from a repository, and is killed after `idle_timeout_ms` without
work (10000 to 3600000, default 300000) or after any protocol failure.
`command` and `timeout_ms` follow the `agent_descriptions` bounds. Run the
engine without tools and without project context unless a feature needs
them:

```lua
engine = {
  command = {
    "pi", "--mode", "rpc", "--no-session", "--no-tools",
    "--no-extensions", "--no-skills", "--no-context-files",
  },
  timeout_ms = 20000,
  idle_timeout_ms = 300000,
}
```

See [Agent engine](flows/engine.md) for the runtime path. With an engine
configured, `prefix+?` (`telar.action.suggest_command()`) opens the
[command suggestion](flows/suggest-command.md) palette: it sends the focused
pane's working directory, its last visible rows and your request to the
engine, and Enter pastes the answer without running it.

`client.icons` accepts `"unicode"`, the default, or `"nerd-font"`. The Nerd
Font theme uses a glyph subset embedded in Telar and does not require a Nerd
Font in the host terminal. It needs Kitty Graphics support and RGB theme
colors. Telar keeps the Unicode cell icons as the fallback when either is
unavailable.

`client.sound` controls audible agent notifications. All three fields default
to `true`. `ready` applies only to `working -> ready`; `needs_input` applies
only to `working -> blocked`. Initial snapshots, reconnects, repeated states,
failures, and transitions from any other state remain silent. Set
`enabled = false` to disable both sounds for that client or profile.

## Agents

`runtime.agents` is an array of agent manifests. A manifest is everything
Telar knows about one coding agent without code: how to recognize it, how to
show it, and which client capability it supports. Telar ships manifests for
`claude`, `codex` and `pi`. Naming one of them extends or overrides the
shipped manifest; any other name creates a new agent that the sidebar, the
`telar agent` command, notifications and the image shelf treat exactly like a
built-in one. At most 16 agents can be configured.

```lua
runtime = {
  agents = {
    {
      -- Required. Lowercase letters, digits, "-", "_" or ".", 1..32 bytes.
      -- It is the machine name shown by `telar agent` and the `provider_name`
      -- clients receive.
      name = "gemini",

      -- Presentation (all optional).
      display_name = "Gemini CLI",        -- sidebar label; defaults to name (max 32 bytes)
      placeholder = "New Gemini chat",    -- title before the agent has one;
                                          -- defaults to "New <display_name> session"
      icon = "G",                         -- one glyph, exactly one cell wide;
                                          -- built-ins use Telar's artwork when unset

      -- Identity: how the foreground process is recognized (optional, max 4 each).
      process_names = { "gemini" },                 -- executable basenames, launcher
                                                    -- suffixes (.exe/.cmd/.bat/.js) ignored
      process_paths = { "/@google/gemini-cli/" },   -- entry-point path fragments for
                                                    -- interpreter launches (node, python)

      -- Screen phrases: case-insensitive substrings of the pane's output
      -- (optional, max 8 each, max 48 bytes each).
      brand = { "gemini" },          -- attributes a generic working/blocked phrase to this agent
      identity = { "gemini cli" },   -- confirms identity on screen without proving readiness
      working = { "esc to cancel" },
      blocked = { "allow this tool?" },
      ready_prompt = { "type your message" },  -- proves the agent is idle; an agent that
                                               -- declares this is exempt from the generic
                                               -- prompt-glyph scan

      -- Client capability (optional). How the agent's prompt identifies pasted
      -- images; "none" (default for new agents) hides the image shelf.
      attachments = "ordered",       -- "none" | "ordered" | "stable_number" | "pasted_path"
    },
  },
}
```

`attachments` selects the marker scheme documented in
[clipboard images](flows/clipboard-image.md): `ordered` renumbers `[Image #N]`
markers after a deletion (Codex), `stable_number` keeps numbers stable (Claude
Code) and `pasted_path` inserts a temporary file path (Pi). The shipped
defaults are `stable_number` for `claude`, `ordered` for `codex` and
`pasted_path` for `pi`.

Overriding a built-in keeps its provider index, artwork and code-level
capabilities; only the listed fields change. For example, relabel Claude Code
and add a working phrase:

```lua
agents = {
  { name = "claude", display_name = "Claude", working = { "brewing" } },
}
```

Three things stay in code and are not configurable, because each needs an
agent-specific program rather than data:

- **Session resume.** Only `claude`, `codex` and `pi` are resumed from a
  checkpoint (`src/backend/agent/providers/`). A configured agent restores as
  a plain shell.
- **Lifecycle hooks.** `telar integration <agent>` and `telar hook <agent>`
  know the hook formats of the three built-ins (`src/cli/`).
- **Network observation.** The proxy recognizes API dialects
  (`anthropic_messages`, `openai_responses`), not agents. Any agent that talks
  to one of those APIs through the proxy gets network-side lifecycle for free;
  an agent talking to another API relies on process detection and phrases.

Diagnostics name the entry and the field, for example
`config.runtime.agents[2].icon must be exactly one cell wide`.

## Bars

`client.bars` controls all three blocks of the bottom bar and the right block
of the top bar. The bottom bar must contain exactly one `telar.bar.tabs()`
source. Tabs keep their built-in behavior; configuration can only choose their
position. The top bar keeps workspace navigation and the sidebar control under
Telar's ownership, so only `top.right` exists. The ProxyTLS badge remains
reserved at the far right whenever interception is active. While the sidebar
is visible, both bars start at its right edge. Hiding the sidebar expands them
to the full client width.

```lua
bars = {
  bottom = {
    left = telar.bar.metrics(),
    center = telar.bar.tabs(),
    right = telar.bar.dynamic({
      every_ms = 1000,
      render = function(ctx)
        return {
          { icon = "battery-full", text = string.format(" %d%%  ", ctx.metrics.battery_percent or 0), fg = "green" },
          { text = string.format("%02d:%02d:%02d ", ctx.time.hour, ctx.time.minute, ctx.time.second), fg = "text", bold = true },
        }
      end,
    }),
  },
  top = {
    right = telar.bar.static({
      { icon = "provider-codex", text = " telar ", fg = "accent", bold = true },
    }),
  },
}
```

When `client.bars` is absent, the bottom bar keeps metrics on the left and tabs
on the right, and `top.right` is empty. If `bottom` is present, omitted
positions are empty and one declared position still has to contain the tabs.
Prefix mode, copy mode and a rename prompt temporarily replace the configured
bottom row with their own controls.

Each position accepts one source:

- `telar.bar.tabs()` renders the built-in tabs and is valid only once in the
  bottom bar.
- `telar.bar.metrics()` renders the latest runtime CPU, used-memory and
  optional battery values.
- `telar.bar.static(content)` parses fixed content when the configuration is
  loaded.
- `telar.bar.dynamic({ every_ms, render })` calls `render` on a client-owned
  tick.
- `telar.bar.command({ command, every_ms, timeout_ms, render })` runs an argv
  array outside the client loop. `render` is optional; without it, trimmed
  stdout becomes plain content.

Content may be `nil`, a string, one segment table, or an array of at most 16
segments. A segment accepts these fields:

```lua
{
  text = " 74%",
  icon = "battery-three-quarters",
  fg = "green",
  bg = "panel-bg",
  bold = true,
  italic = false,
  faint = false,
  underline = false,
  strikethrough = false,
}
```

`fg` and `bg` accept a theme palette role, `"default"`, `"#RRGGBB"`, or an
indexed terminal color from 0 through 255. Palette roles are `accent`,
`panel-bg`, `surface0`, `surface1`, `surface-dim`, `overlay0`, `overlay1`,
`text`, `subtext0`, `mauve`, `green`, `yellow`, `red`, `blue`, `teal`, and
`peach`. Names are case-insensitive and hyphens may replace underscores.

The icon names are `sidebar-collapse`, `sidebar-expand`, `workspace-menu`,
`proxy-active`, `cpu`, `memory`, `battery-empty`, `battery-quarter`,
`battery-half`, `battery-three-quarters`, `battery-full`, `provider-unknown`,
`provider-claude`, `provider-codex`, `agent-unknown`, `agent-working-0` through
`agent-working-3`, `agent-blocked`, `agent-ready`, `agent-failed`, and `close`.
They follow the configured Unicode or graphical icon theme.

### Dynamic context

A dynamic or command render callback receives one immutable table. Tab indices
are one-based in Lua.

```lua
{
  sidebar_visible = true,
  tab_count = 3,
  active_tab_index = 2,
  pane_count = 4,
  focused_pane_id = 19,
  time = {
    unix_seconds = 1788278709,
    year = 2026, month = 9, day = 1,
    hour = 13, minute = 5, second = 9,
    weekday = 2, -- Sunday is 0
  },
  metrics = {
    available = true,
    cpu_percent = 38,
    memory_used_decigib = 123,
    battery_percent = 61, -- absent on hosts without a battery
  },
  output = "74%", -- present only in a command render callback
}
```

`every_ms` defaults to 1000 and must be between 100 and 3,600,000. Each source
owns one deadline. If a client is delayed, expired ticks collapse into one
evaluation instead of replaying every missed value. Lua evaluation keeps the
same instruction, memory and 10 ms wall-time containment as other client
callbacks. A failure leaves the last valid content in place and publishes a
bounded client diagnostic.

Commands contain 1 to 32 arguments and at most 4096 argument bytes. Telar
executes the argv directly, without a shell, and inherits the client's process
environment and working directory. `timeout_ms` defaults to 2000 and must be
between 100 and 10000. Stdout is limited to one valid UTF-8 display line of at
most 512 bytes; stderr is bounded to 4096 bytes. All bar commands share one
worker, and another elapsed tick records only one pending rerun. Reloading the
configuration discards a completion from the previous generation.

For example, a subscription quota helper can be polled without giving Lua
filesystem, process or network authority:

```lua
top = {
  right = telar.bar.command({
    command = { "telar-quota" },
    every_ms = 60000,
    timeout_ms = 2000,
    render = function(ctx)
      return { icon = "provider-codex", text = " " .. ctx.output .. " ", fg = "accent" }
    end,
  }),
}
```

The helper owns any credentials and network access it needs. Telar receives
only its bounded stdout. See [Configurable bars](flows/configurable-bars.md)
for ownership, scheduling and stale-result behavior.

## Bindings

`client.prefix` is one key chord and defaults to `"ctrl+b"`. `telar.bind` and
`telar.bind_expr` prepend it to their `keys`, so `{ "s" }` matches
`prefix`, then `s`. Changing the prefix also changes the compiled default
keymap and prefixed bindings inherited by a profile. Pressing the prefix enters
a persistent client mode: it waits without a deadline for the next key. A valid
suffix runs its action, an invalid suffix is consumed, and Escape cancels the
mode. The bottom bar shows a bounded set of useful bindings from the effective
keymap while the mode is active.

Use `telar.bind_global` and `telar.bind_expr_global` for sequences that must not
use the prefix. A prefixed binding accepts one to four suffix keys. A global
binding accepts one to five keys. `client.keybindings` extends the default
keymap. A configured binding replaces every conflicting default. A conflict is
the same key sequence, or a sequence that is a prefix of the other, since the
keymap refuses ambiguous prefixes. Defaults free of conflicts remain active.
`telar config check` compiles the merged keymap and reports conflicts between
configured bindings. `client.input.sequence_timeout_ms` applies only to partial
global sequences; prefixed sequences do not expire.

`telar.bind` and `telar.bind_global` accept a semantic built-in action, a
constructor such as `split_pane`, `focus_pane`, `select_tab`,
`resize_pane`, `resize_sidebar`, `select_tab_offset`, `move_tab`, or `plugin`, or a Lua callback. The
`telar.bind_expr` variants require a Lua callback. Built-in action names are
stable configuration API; Lua never emits terminal bytes or calls internal Zig
state.

`telar.action.resize_pane({ direction = ... })` accepts `"left"`, `"right"`,
`"up"`, or `"down"`. Each invocation moves the nearest matching split edge by
5%. Telar refuses a resize that would leave any pane without a content cell.
The default bindings are `prefix`, then `shift+left`, `shift+right`, `shift+up`,
or `shift+down`.

`telar.action.resize_sidebar({ direction = ... })` accepts `"left"` to narrow
the sidebar and `"right"` to widen it, two columns per invocation. The default
bindings are `prefix`, then `alt+left` or `alt+right`. Dragging the sidebar's
rightmost column selects an exact width. Telar always reserves at least 42
columns for the sidebar and 20 for the workbench; a narrower host temporarily
hides or clamps the sidebar without discarding its preferred width.

`telar.action.copy_mode()` enters the focused pane's scrollback. Its default
binding is `prefix`, then `[`. In copy mode, the mouse wheel scrolls three rows
per notch while it is over the target pane and other mouse actions are ignored.
Outside copy mode, applications that own mouse reporting keep receiving wheel
events, and an alternate-screen application with alternate-scroll enabled
receives cursor keys instead. Normal pane input returns the viewport to the
bottom.

Copy mode accepts `h`, `j`, `k`, `l` and the arrow keys, `w`, `b`, `e`, `{`,
`}`, `0`, `^`, `$`, `g`, `G`, Page Up, Page Down, Ctrl-B, Ctrl-F, Ctrl-U, and Ctrl-D.
Press `v` or Space for a character selection, `V` for a line selection, then
`y` or Enter to copy through OSC 52. Escape first clears an active selection;
a second Escape, or `q`, leaves copy mode and restores the entry viewport.
The bottom bar replaces metrics and tabs with these movement, selection, copy,
and exit hints until copy mode ends. Pressing the configured prefix temporarily
replaces them with the prefix-mode hints.

`telar.action.toggle_pane_fullscreen()` makes the focused pane occupy the whole
tab. The client retains the tiled layout and its split ratios, so invoking the
action again restores the previous geometry. Directional focus still selects
another pane while fullscreen is active. The default binding is `prefix`, then
`z`. A tab with one pane ignores the action.

`telar.action.toggle_workspace_list()` collapses the top bar's list of open
workspaces to the active one plus a `+N` counter, and expands it again.
Clicking the `❖` marker or the counter does the same; clicking a workspace
name switches to it. The collapse state belongs to the client layout, and the
runtime retains it for the same terminal while the server is alive. The default
binding is `prefix`, then `w`.

`telar.action.notification(options)` publishes a toast through the runtime.
It accepts a required `title`, optional `body`, `level` (`info`, `success`,
`warning`, or `failure`), and `duration_ms` from 500 to 60000. At most one of
`pane_id`, `tab_id`, or `workspace_id` may be supplied; it becomes the action
performed when the toast is clicked.

```lua
telar.bind({ "n" }, function(ctx)
  return telar.action.notification({
    title = "Agent waiting",
    body = "Review its question",
    level = "warning",
    pane_id = ctx.focused_pane_id,
  })
end)
```

The runtime broadcasts the event to every connected UI client. Each client
owns its bounded toast queue, animation, dismissal, and stale-target checks.
See [`notifications.md`](notifications.md) for the CLI and plugin interfaces.

A callback receives an immutable snapshot:

```lua
telar.bind({ "s" }, function(ctx)
  -- sidebar_visible, tab_count, active_tab_index, pane_count, focused_pane_id
  if ctx.sidebar_visible then
    return telar.action.toggle_sidebar()
  end
  return {}
end)
```

It returns one action or a bounded array of actions. Telar validates the whole
batch before applying it. Callback memory, instructions, wall time, and output
are bounded. An error consumes the matched binding and appears in the client's
diagnostic banner.

`telar.bind_expr` transforms input semantically. Its callback returns one of:

- `telar.input.consume()`;
- `telar.input.forward()`;
- `telar.input.key("left")`;
- `telar.input.keys({ "left", "enter" })`;
- `telar.input.paste("text")`.

The client encodes the result for the focused pane's current cursor, keypad,
and bracketed-paste modes. Raw terminal escape sequences are not part of the
Lua API.

See [Lua action](flows/lua-action.md) for VM ownership, validate-before-apply
ordering, model-owned diagnostics and the semantic input path.

## Environment and reload

The configuration VM exposes base, coroutine, math, string, table, and UTF-8
libraries. It does not expose `io`, `os`, `debug`, native modules, dynamic code
loading, or mutable metatables. `require("telar")` returns the API and local
module names resolve only beneath the directory containing `config.lua`.

The client watches the main file, loaded local modules, configured plugin
trees, and the trust store. A change builds a complete replacement generation.
Theme, sidebar, keymap, callbacks, plugin registry, and grants swap only after
all validation succeeds. A failure leaves the previous generation active and
shows the error in the client. Closure state is intentionally lost on reload.
The client model records the accepted generation, sidebar and pane-gap state;
the presenter observes that version and paints the new appearance on its paced
frame. The ownership and failure order is mapped in
[`flows/config-reload.md`](flows/config-reload.md).

The runtime evaluates the same file in a disposable VM and retains only typed,
validated values. No Lua state or closure enters the runtime process.
`runtime.history.path` is resolved relative to the directory containing
`config.lua`; its parent directory must already exist. `runtime.proxy` accepts
`enabled`, `ca_dir`, and `intercept_hosts`. ProxyTLS is disabled by default. A
relative `ca_dir` is also resolved beside `config.lua`; Telar creates it
owner-only and stores its private CA and derived trust bundle there with
owner-only file permissions. `intercept_hosts` accepts at most 256 exact DNS
hostnames within a 64,768-byte budget. It defaults to `api.anthropic.com`,
`api.openai.com`, and `chatgpt.com`; an explicitly configured array replaces
the defaults, including with an empty array. Telar canonicalizes case, sorts
the set, and removes duplicates when the runtime starts. Wildcards are
rejected. Every other connection still passes through Telar's authenticated
CONNECT listener, but its TCP payload is forwarded opaquely and is not
observed.
Explicit server CLI
graphics limits still override the Lua values. Runtime-owned settings take
effect when the long-lived runtime starts; restart that runtime to apply a
changed runtime profile.

No proxy callback is accepted by the runtime configuration today. The native
proxy exposes bounded observation and semantic head-transformation contracts
for a later isolated Lua worker. Method, target, status, and header effects are
already validated consistently for HTTP/1.1 and HTTP/2, while bodies remain
streaming and unavailable to callbacks. Placing a live closure in
`runtime.proxy` is rejected so Lua cannot enter the runtime or a
traffic-forwarding actor accidentally. See
[`proxy-tls.md`](proxy-tls.md) for the trust, observation, and future middleware
contracts.
