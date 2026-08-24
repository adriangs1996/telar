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

The file must return a table with `api_version = 1`. Unknown fields are errors.
The complete schema is demonstrated by [`examples/config.lua`](../examples/config.lua).

```lua
local telar = require("telar")

return telar.config({
  api_version = 1,
  client = {
    theme = telar.theme({
      base = "vesper",
      colors = { accent = "#ffc799" },
    }),
    sidebar = { visible = true, renderer = "automatic" },
    input = { escape_timeout_ms = 25, sequence_timeout_ms = 1000 },
    keybindings = {
      telar.bind({ "ctrl+b", "s" }, telar.action.toggle_sidebar()),
    },
  },
  runtime = {
    history = { path = "state/history.db" },
    graphics = { pane_mib = 64, global_mib = 256 },
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

`telar.bind(keys, action)` accepts a semantic built-in action, a constructor
such as `split_pane`, `focus_pane`, `select_tab`, `select_tab_offset`,
`move_tab`, or `plugin`, or a Lua callback. Built-in action names are stable
configuration API; Lua never emits terminal bytes or calls internal Zig state.

A callback receives an immutable snapshot:

```lua
telar.bind({ "ctrl+b", "s" }, function(ctx)
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
`config.lua`; its parent directory must already exist. Explicit server CLI
graphics limits still override the Lua values. Runtime-owned settings take
effect when the long-lived runtime starts; restart that runtime to apply a
changed runtime profile.
