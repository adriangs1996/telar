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
    theme = telar.theme({
      base = "vesper",
      colors = { accent = "#ffc799" },
    }),
    sidebar = { visible = true, renderer = "automatic" },
    input = { escape_timeout_ms = 25, sequence_timeout_ms = 1000 },
    keybindings = {
      telar.bind({ "s" }, telar.action.toggle_sidebar()),
      telar.bind({ "shift+left" }, telar.action.resize_pane({ direction = "left" })),
      telar.bind({ "z" }, telar.action.toggle_pane_fullscreen()),
      telar.bind_global({ "ctrl+shift+s" }, telar.action.detach()),
    },
  },
  runtime = {
    history = { path = "state/history.db" },
    graphics = { pane_mib = 64, global_mib = 256 },
    proxy = { enabled = false, ca_dir = "state/proxy" },
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

## Bindings

`client.prefix` is one key chord and defaults to `"ctrl+b"`. `telar.bind` and
`telar.bind_expr` prepend it to their `keys`, so `{ "s" }` matches
`prefix`, then `s`. Changing the prefix also changes the compiled default
keymap and prefixed bindings inherited by a profile.

Use `telar.bind_global` and `telar.bind_expr_global` for sequences that must not
use the prefix. A prefixed binding accepts one to four suffix keys. A global
binding accepts one to five keys. Setting `client.keybindings` replaces the
default keymap; it does not extend it.

`telar.bind` and `telar.bind_global` accept a semantic built-in action, a
constructor such as `split_pane`, `focus_pane`, `select_tab`,
`resize_pane`, `select_tab_offset`, `move_tab`, or `plugin`, or a Lua callback. The
`telar.bind_expr` variants require a Lua callback. Built-in action names are
stable configuration API; Lua never emits terminal bytes or calls internal Zig
state.

`telar.action.resize_pane({ direction = ... })` accepts `"left"`, `"right"`,
`"up"`, or `"down"`. Each invocation moves the nearest matching split edge by
5%. Telar refuses a resize that would leave any pane without a content cell.
The default bindings are `prefix`, then `shift+left`, `shift+right`, `shift+up`,
or `shift+down`.

`telar.action.copy_mode()` enters the focused pane's scrollback. Its default
binding is `prefix`, then `[`. The mouse wheel scrolls three rows per notch;
applications that own mouse reporting keep receiving wheel events, and an
alternate-screen application with alternate-scroll enabled receives cursor
keys instead. Normal pane input returns the viewport to the bottom.

Copy mode accepts `h`, `j`, `k`, `l` and the arrow keys, `w`, `b`, `e`, `{`,
`}`, `0`, `^`, `$`, `g`, `G`, Page Up, Page Down, Ctrl-B, Ctrl-F, Ctrl-U, and Ctrl-D.
Press `v` or Space for a character selection, `V` for a line selection, then
`y` or Enter to copy through OSC 52. Escape first clears an active selection;
a second Escape, or `q`, leaves copy mode and restores the entry viewport.

`telar.action.toggle_pane_fullscreen()` makes the focused pane occupy the whole
tab. The client retains the tiled layout and its split ratios, so invoking the
action again restores the previous geometry. Directional focus still selects
another pane while fullscreen is active. The default binding is `prefix`, then
`z`. A tab with one pane ignores the action.

`telar.action.toggle_workspace_list()` collapses the top bar's list of open
workspaces to the active one plus a `+N` counter, and expands it again.
Clicking the `❖` marker or the counter does the same; clicking a workspace
name switches to it. The collapse state is client-only and is lost when the
client exits. The default binding is `prefix`, then `w`.

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

The runtime evaluates the same file in a disposable VM and retains only typed,
validated values. No Lua state or closure enters the runtime process.
`runtime.history.path` is resolved relative to the directory containing
`config.lua`; its parent directory must already exist. `runtime.proxy` accepts
only `enabled` and `ca_dir`. ProxyTLS is disabled by default. A relative
`ca_dir` is also resolved beside `config.lua`; Telar creates it owner-only and
stores its private CA and derived trust bundle there with owner-only file
permissions. Explicit server CLI
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
