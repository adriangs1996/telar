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
  theme = telar.theme({
    base = "vesper",
    colors = { accent = "#ffc799" },
  }),
  client = {
    prefix = "ctrl+s",
    sidebar = { visible = true },
    sound = { enabled = true, ready = true, needs_input = true },
    input = { sequence_timeout_ms = 1000 },
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
      capture = {
        enabled = false,
        max_part_bytes = 16 * 1024 * 1024,
        max_exchange_bytes = 32 * 1024 * 1024,
        max_total_bytes = 128 * 1024 * 1024,
        join_timeout_ms = 15 * 60 * 1000,
      },
      intercept_hosts = { "api.example.com" },
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
      client = { sidebar = { visible = false } },
      runtime = { graphics = { pane_mib = 16, global_mib = 64 } },
    },
  },
})
```

### Retired keys

Some keys only meant something to the retired terminal client. A file that
still sets one loads without it: Telar ignores the key, keeps its default and
says which keys it ignored, in a notice in the window when the file loads or
reloads and as a warning from `telar config check`. A retired key never keeps
the window or the runtime from starting. Remove them from older files:

- `client.sidebar.renderer` chose how the terminal client drew its sidebar;
  the window draws its own.
- `client.notifications.delivery = "terminal"` wrote notices to the terminal
  client's outer terminal; the delivery stays `telar`. See
  [notifications](notifications.md#delivery-channels).
- `client.input.escape_timeout_ms` was how long the terminal client waited
  for the rest of an escape sequence; the window receives whole keys.
- `client.icons` chose between the terminal client's Unicode and Nerd Font
  icon sets; the window always draws the Nerd Font subset embedded in Telar,
  so no Nerd Font needs to be installed.

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

`client.editor` selects the executable used to open local file links. For example,
`client = { editor = "/opt/homebrew/bin/nvim" }` works without `$EDITOR` in the
GUI environment. The value must be a nonempty executable name or path, at most
4096 bytes. It is executed directly, with the file path as a separate argument;
shell commands, flags and `~` expansion are not interpreted. A bare name is
resolved using the runtime's `PATH`.

The selected profile can override the base value. Removing the option restores
the client's startup `$EDITOR`; if neither is set, opening a file reports
`EditorUnavailable`. Reloading the configuration changes future file openings
without restarting existing editor panes.

`client.sound` controls audible agent notifications. All three fields default
to `true`. `ready` applies only to `working -> ready`; `needs_input` applies
only to `working -> blocked`. Initial snapshots, reconnects, repeated states,
failures, and transitions from any other state remain silent. Set
`enabled = false` to disable both sounds for that client or profile.

## Theme

Select a theme once at the root of the configuration:

```lua
theme = "shade"
```

Each preset defines Telar's chrome roles and the native terminal's foreground,
background, ANSI palette and cursor colors. Built-ins are `shade` (the default),
`vesper`, `catppuccin` (Mocha), `tokyo-night`, `pierre-dark`,
`pierre-dark-soft`, and `terminal`. The Pierre presets use the dark and dark-soft
palettes from Adrian's Neovim theme, including syntax and ANSI colors. Shade
combines Vesper's neutral grays and terminal palette with green chrome accents.
The old names `osaka-jade`, `osaka_jade`, and `osakajade` remain aliases for Shade.
Shade's `panel_bg` is `default`: the chrome takes the terminal background,
which the window paints `#101010`. The window uses the preset's terminal
colors; child truecolor and OSC overrides still apply. The `terminal` preset
uses host-relative chrome roles and a neutral explicit palette, since the
window has no exterior terminal to inherit from.

To customize a preset, use the table form. Each section is optional:

```lua
theme = telar.theme({
  base = "vesper",
  colors = { accent = "#a8c98c" },
  terminal = { background = "#111c18", cursor_color = "#a8c98c" },
  syntax = {
    keyword = "#a0a0a0",
    func = "#a8c98c",
    parameter = { fg = "#add0c5", italic = true },
  },
})
```

`syntax` overrides code colors and styles independently of chrome and ANSI.
Its roles are `plain`, `keyword`, `string`, `number`, `comment`, `constant`,
`builtin_constant`, `builtin`, `func`, `type`, `parameter`, `property`,
`namespace`, `operator` and `punctuation`. A role accepts a color string or a
table with `fg`, `italic` and `bold`. Omitted fields inherit their current
values; selecting a new preset replaces the complete theme. Colors accept
`#RRGGBB` or `"default"`.

Shade and both Pierre presets define explicit syntax styles from their Neovim
palettes. Shade uses gray keywords, green functions, pale green types, peach
numbers and italic mint parameters. Other presets derive unspecified roles from
their chrome palette. Explicit `syntax` values take precedence over these defaults.
The native diff viewer uses bundled Tree-sitter grammars and highlight queries.
Available categories depend on each language's query; defining a style does
not enable LSP semantic analysis. Theme changes recolor retained tokens.

`colors` overrides chrome roles such as `accent`, `panel_bg`, `text` and
`surface0`. These accept `#RRGGBB` or `"default"`. `terminal` accepts explicit
RGB values only:

| Setting in `theme.terminal` | Meaning |
| --- | --- |
| `foreground` | Default terminal text color. |
| `background` | Terminal background, including unused edge pixels outside the grid. |
| `palette` | Exactly 16 `#RRGGBB` strings in ANSI order: Lua indices `1..8` are normal, `9..16` bright. Indices `16..255` retain the xterm color cube and grayscale ramp. |
| `cursor_color` | Cursor fill or outline. Uses the preset's value, or terminal foreground when unspecified. |
| `cursor_text_color` | Glyph color inside a filled block cursor. Uses the preset's value, or terminal background when unspecified. |

A name or explicit `base` selects a complete preset and discards inherited
color overrides. A table without `base` overlays the current theme, so a
profile can change only its background without copying a palette. `--theme`
overrides the complete theme and remains locked across reloads; it does not
lock fonts or cursor behavior.

`client.theme` remains an alias for older configurations and selects the
same complete theme. Set either `theme` or `client.theme` at a given root/profile
level; declaring both is an error. The earlier `gui.theme` table has moved to
`theme.terminal`. Likewise, `gui.cursor.color` and `gui.cursor.text_color` move
to `theme.terminal.cursor_color` and `theme.terminal.cursor_text_color`.

Shade inherits Vesper's terminal colors unchanged. The ANSI data comes from the [Vesper terminal port](https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/ghostty/Vesper),
[Catppuccin Mocha](https://github.com/catppuccin/ghostty/blob/main/themes/catppuccin-mocha.conf)
and [Tokyo Night](https://github.com/folke/tokyonight.nvim/blob/main/extras/ghostty/tokyonight_night).
Telar retains its orange Vesper cursor with background-colored text.

## Graphical application

`gui` configures the window, fonts and cursor behavior in `telar gui`. Colors come from the
root `theme`.
See [`examples/gui.lua`](../examples/gui.lua) for a complete runnable example:

```sh
telar config check examples/gui.lua
telar gui --config examples/gui.lua
telar gui --config examples/gui.lua --profile presentation
```

```lua
theme = "shade"
gui = {
  window = {
    titlebar = false, -- the macOS default; Linux defaults to true
    background_opacity = 0.95,
    background_blur = 20,
    padding = { x = 8, y = 8 },
  },
  font = {
    family = "JetBrains Mono",
    size = 15,
    line_height = 1.15,
    letter_spacing = 0,
    thicken = false, -- macOS optical smoothing
    thicken_strength = 255,
  },
  cursor = { style = "block", blink = true, blink_interval_ms = 600 },
  chrome = { scale = 1 },
  sidebar = { width = 284 },
}
```

| Setting | Default | Meaning and bounds |
| --- | --- | --- |
| `window.titlebar` | `false` on macOS, `true` on Linux | Show the native titlebar. On macOS it starts transparent: the traffic lights stay visible and share Telar's top bar, which sits at the window edge; set `true` to restore the native titlebar above it. On Wayland it defaults to the compositor decoration and is a request which the compositor may override. Telar's workspace, tab and status bars remain available either way. |
| `window.background_opacity` | `1` | Background opacity, `0..1`. Below `1`, the sidebar, bars and pane headers share the window's terminal background, regardless of the theme's `panel_bg`. At `1`, panels use `panel_bg`. Text, cursor, controls, modals and cell backgrounds differing from the terminal default retain their own opacity. |
| `window.background_blur` | `0` | Integer `0..255`: macOS blur radius, with `0` disabling blur. On Wayland any positive value requests compositor blur; its intensity remains compositor-controlled. Has no visible effect at opacity `1`. Legacy `true` means `20`, and `false` means `0`. |
| `window.padding.x` | `0` | Logical pixels on each horizontal edge, `0..256`, decimals allowed. |
| `window.padding.y` | `0` | Logical pixels on each vertical edge, `0..256`, decimals allowed. |
| `font.family` | bundled JetBrains Mono | Installed family name, at most 256 UTF-8 bytes, without NUL. An empty name or `JetBrains Mono` uses the bundled face. |
| `font.size` | `15` | Logical pixel size, equivalent to points on macOS; `6..96`, decimals allowed. The display scale is applied once during rasterization. |
| `font.line_height` | `1.0` | Multiplier of the font's natural line height; `0.75..3`. Extra space is distributed above and below the baseline. |
| `font.letter_spacing` | `0` | Extra logical pixels per cell; `-5..20`. A combination producing a nonpositive cell width fails at startup or rejects the reload. |
| `font.thicken` | `false` | Enable CoreGraphics optical font smoothing on macOS. Increases stroke coverage without changing cell metrics or the terminal's bold attribute. Ignored on Linux. |
| `font.thicken_strength` | `255` | Integer `0..255`, active only with `thicken = true` on macOS. `0` is the lightest smoothing, not disabled; `255` is the strongest. |
| `cursor.style` | `block` | `block`, `bar`, `underline`, or `hollow`. |
| `cursor.blink` | `true` | Whether the default cursor blinks. An explicit application DECSCUSR style overrides this default; DEC mode 12 can suppress blinking. |
| `cursor.blink_interval_ms` | `600` | Duration of each visible or hidden phase; integer `100..5000`. |
| `sidebar.width` | `284` | Width of the native sidebar band in logical pixels; `220..480`, decimals allowed. Scaled by the display and rounded to device pixels, then clamped so the workbench keeps at least 20 columns after the band and its 8 px gap; a window too narrow for the narrowest band hides it. Keyboard `resize_sidebar` moves the width by 16 logical pixels and dragging the edge sets it exactly; both change only this window and are not written back to the file, so the value here is what a new window starts from. A reload that changes the value replaces the window's width; one that leaves it unchanged keeps an interactive choice. |
| `chrome.scale` | `1` | Multiplies the native chrome text sizes; `0.5..2`, decimals allowed. The chrome derives three sizes from `font.size` times the display scale: title and body ×0.87, small ×0.73, rounded to device pixels and never below 6. The bands (top navigation 42, status bar 26, pane header 22 logical pixels) do not scale with it, so the body size is capped at the largest whose line box fits the pane header: at `font.size = 15` the body stops growing at 16 px (scale ≈ 1.3) while title and small keep growing, reaching 26 and 22 px at scale 2. The terminal grid and the PTY size never change with it; a reload applies it without rebuilding the atlas. |

Padding is applied once at the display scale, then rounded to physical pixels.
It belongs to the window, outside the terminal grid; PTY pixel sizes contain
only complete cells. Insets shrink when necessary to leave room for at least
one cell. Changing padding can change `stty size` without changing the font.
While the sidebar is visible its band and gap replace the left inset; the
right inset stays `padding.x`.

macOS adjusts the WindowServer blur radius through the same optional private
API used by Ghostty. If the API is unavailable or rejects the request, Telar
reports it once and falls back to `NSVisualEffectView` with a system-controlled
intensity. This effect blurs the content behind the window, keeping terminal
text sharp. On Wayland, blur uses `ext-background-effect-v1` when the compositor
advertises blur capability; the protocol exposes no radius setting.
An unsupported compositor keeps transparency and reports the missing blur
capability once on stderr. A Vulkan surface without premultiplied-alpha support
falls back to an opaque background with a diagnostic. See
[Ghostty's blur reference](https://ghostty.org/docs/config/reference#background-blur)
for the same platform distinction.

Titlebar changes apply on reload. macOS preserves the outer window rectangle
and keyboard focus, and measures the terminal again when the content area
changes. A preference changed during a fullscreen transition takes effect
after returning to a normal window. Wayland uses `xdg-decoration`; without
that protocol, Telar does not draw its own titlebar.

`theme.terminal` requires explicit RGB values; `"default"` has no exterior
terminal to refer to here. Child truecolor and OSC palette/default-color overrides still
work. The runtime receives the geometry owner's default foreground, background
and ANSI palette so OSC 4/10/11 queries agree with that host; OSC 104/110/111
restores those defaults. Another connection retains its own GUI preferences.

Font resolution uses CoreText on macOS and Fontconfig on Linux at startup and
when a reload changes font settings. An unavailable explicitly named family is
an error. `config check` validates the schema without requiring that font on
the checking machine.
With `font.thicken = true`, macOS rasterizes the selected face through CoreText
and CoreGraphics into the existing glyph atlas. FreeType still supplies metrics
and HarfBuzz shaping, so toggling optical weight preserves the grid and PTY size.
Bold and italic use the existing synthesized variants. A grapheme the
configured font lacks falls back to the embedded JetBrains Mono and Nerd
Symbols faces, then to an installed system font found automatically through
CoreText or Fontconfig (monospace preferred, at most eight such faces per
window, fitted to the cell); nothing configures this. Fallback is monochrome:
color emoji faces are never selected, so a grapheme only they cover keeps the
face's replacement glyph. Separate style families, fallback family lists,
OpenType feature configuration, color emoji and zoom shortcuts are not part of
this increment. Chrome can derive proportional sizes from `GuiFont.scaledSize`.

The cursor follows the VT's visibility and DECSCUSR requests, including changes
an editor emits when entering insert mode. It shows a steady hollow outline
when the native window loses focus. Input, cursor changes and focus restart the
visible phase. Cursor colors currently come from Lua; application OSC 12 cursor
color overrides are not projected to the GUI yet.

The GUI reloads a loaded configuration automatically. Save the Lua file or one
of its imported modules; the shared watcher checks for changes every second.
Profiles overlay only the fields they specify, and reload keeps the profile
selected at launch. Saving by atomic file replacement also works.

Lua validation and font preparation run off the window thread. A complete
replacement becomes active once the previous GPU frame releases its resources.
Font geometry, padding and sidebar width changes update the terminal grid and PTY size. Optical
weight changes replace the macOS atlas without resizing the PTY. An inactive
strength change, or either optical weight setting on Linux, preserves the atlas. Window effects,
theme and cursor changes
reuse the existing glyph atlas. Input and receipt ACKs continue during loading.
Invalid Lua, a missing font or invalid metrics leave the previous generation
active and report a diagnostic on stderr. Correct the file and save again to
retry. `--no-config` disables watching; a window started without a loaded config
must be reopened with one before automatic reload is available.

The selected options were informed by [Ghostty's configuration
reference](https://ghostty.org/docs/config/reference); Telar does not load
Ghostty configuration files. See [native appearance](flows/native-appearance.md)
for the code path, resource lifetime and verification.

## Agents

`runtime.agents` is an array of agent manifests. A manifest is everything
Telar knows about one coding agent without code: how to recognize it, how to
show it, and which client capability it supports. Telar ships manifests for
`claude`, `codex`, `pi`, `cursor` and `opencode`. Naming one of them extends or overrides the
shipped manifest; any other name creates a new agent that the sidebar, the
`telar agent` command, notifications and the image shelf treat exactly like a
built-in one. Up to 16 agents can be configured besides the built-in ones.

A manifest past a limit keeps what fits and the rest of the configuration
loads: a 17th new agent, list entries past a list's room and entries longer
than their bound are left out, and each limit reached is reported with the
limit notice (`agent_manifest.max_custom_agents`, `agent_manifest.max_phrases`,
`agent_manifest.max_phrase_bytes`, `agent_manifest.max_paths`,
`agent_manifest.max_path_bytes`, `agent_manifest.max_command_tools`) and
listed by `telar diagnostics limits`. Configured entries extend a built-in
list, and every built-in list leaves at least half its room free.

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

      -- Identity: how the foreground process is recognized (optional, max 8 each,
      -- max 128 bytes each).
      process_names = { "gemini" },                 -- executable basenames, launcher
                                                    -- suffixes (.exe/.cmd/.bat/.js) ignored
      process_paths = { "/@google/gemini-cli/" },   -- entry-point path fragments for
                                                    -- interpreter launches (node, python)

      -- Screen phrases: case-insensitive substrings of the pane's visible
      -- screen, not of its byte stream (optional, max 16 each, max 64 bytes each).
      brand = { "gemini" },          -- attributes a generic working/blocked phrase to this agent
      identity = { "gemini cli" },   -- confirms identity on screen without proving readiness
      working = { "esc to cancel" },
      blocked = { "allow this tool?" },
      ready_prompt = { "type your message" },  -- proves the agent is idle; an agent that
                                               -- declares this is exempt from the generic
                                               -- prompt-glyph scan

      -- Shell tools reported by this agent's native hooks (optional, max 8).
      -- Both values are 1..64 and 1..32 bytes respectively.
      command_tools = {
        { tool = "Bash", field = "command" },
      },

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

`command_tools` maps a hook's exact tool name to the string field that contains
the shell command in `tool_input`. It lets a custom harness participate in
native command history without adding provider-specific code. Entries with a
missing mapping, a non-string field or a subagent id are ignored. The shipped
manifests map Claude Code `Bash.command`, Codex `Bash.command` plus the legacy
`exec_command.cmd` and `shell.command` names, and Pi `bash.command`.

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

- **Session resume.** Only `claude`, `codex`, `pi`, `cursor` and `opencode` are resumed from a
  checkpoint (`src/backend/agent/providers/`). A configured agent restores as
  a plain shell.
- **Lifecycle hooks.** `telar integration <agent>` and `telar hook <agent>`
  know the hook formats of the five built-ins (`src/cli/`).

Diagnostics name the entry and the field, for example
`config.runtime.agents[2].icon must be exactly one cell wide`.

## Bars

`client.bars` declares three bottom slots, a `top.right` slot and the sidebar
footer row. The shared configuration requires exactly one `telar.bar.tabs()`
source in `bottom`.

The native app keeps workspace navigation and tabs together in its top bar.
Its configurable components occupy the full-width bottom bar: `bottom.left`,
`bottom.center` and `bottom.right` retain their order and alignment, while
`telar.bar.tabs()` leaves its slot empty because the tabs are already above.
Existing `top.right` content follows the right slot, immediately before the
reserved TLS badge, so existing configurations stay visible. The TLS badge has
priority over every component and remains visible while interception is active
or Telar's system trust is installed.

A bar is built from components that Telar draws itself: the configuration says
what to show and Telar decides how it looks, so a bar follows the theme, the
chrome's type sizes and spacing. [`docs/examples/bar`](examples/bar/config.lua) recreates a clock, host
metrics and agent quotas with detail panels from any data source.

```lua
local telar = require("telar")
local ui = telar.ui

bars = {
  bottom = {
    left = telar.bar.static({
      ui.clock("%H:%M"),
      ui.metrics({ "battery", "cpu", "memory" }),
    }),
    center = telar.bar.tabs(),
    right = telar.bar.command({
      command = { "my-quota", "--json" },
      every_ms = 60000,
      render = function(ctx)
        local quota = telar.json.decode(ctx.output)
        return ui.group({
          mark = "claude",
          on_click = telar.action.open_panel("claude"),
          tooltip = { ui.meter_row({ label = "This week", value = quota.week / 100 }) },
          ui.meter({ label = "5h", value = quota.session / 100 }),
          ui.meter({ label = "7d", value = quota.week / 100, tone = quota.week >= 80 and "danger" or "neutral" }),
        })
      end,
    }),
  },
}
```

When `client.bars` is absent, the bottom slots contain metrics on the left and
tabs on the right and `top.right` is empty. If
`bottom` is present, omitted positions are empty and one declared position
still has to contain the tabs.

`sidebar_footer` remains accepted for compatibility, with at most three sources
and no `telar.bar.tabs()`. The window does not display these slots.
Place metrics and other visible components in `bottom` instead.
Prefix and copy mode replace the native bottom components with the mode chip and
key hints, preserving TLS and top navigation.

Each position accepts one source:

- `telar.bar.tabs()` renders the built-in tabs and is valid only once in the
  bottom bar.
- `telar.bar.metrics()` renders the latest runtime CPU, used-memory and
  optional battery values, the same as `telar.bar.static(telar.ui.metrics())`.
- `telar.bar.machines()` renders a chip per machine the window holds, with
  its link state, attention and latest CPU sample, and nothing while the
  window holds only this machine.
  `telar.bar.metrics()` reports the machine the window shows.
- `telar.bar.static(content)` parses fixed content when the configuration is
  loaded.
- `telar.bar.dynamic({ every_ms, render })` calls `render` on a client-owned
  tick.
- `telar.bar.command({ command, every_ms, timeout_ms, render })` runs an argv
  array outside the client loop. `render` is optional; without it, trimmed
  stdout becomes plain content.

### Components

Content may be `nil`, a string, one component, a legacy segment table, or a
list of any of them; nested lists are flattened. Every `telar.ui` constructor
takes a table of fields; the ones marked below also take their main field
alone, as in `ui.clock("%H:%M")`.

| Component | Fields |
| --- | --- |
| `ui.label` | `text` (shorthand), `tone`, and the segment style fields below |
| `ui.icon` | `name` (shorthand), a built-in icon, or `glyph`, one grapheme of at most 16 bytes; `tone` |
| `ui.mark` | `name` (shorthand): `claude`, `codex`, `pi` or `telar`, drawn from Telar's own artwork |
| `ui.meter` | `value` 0..1, `label`, `text` (shown instead of the percentage), `marker` 0..1, `tone` |
| `ui.sparkline` | `values`, non-negative numbers, of which the last 120 are kept; `max` (their largest by default); `tone` |
| `ui.badge` | `text` (shorthand), `tone` |
| `ui.clock` | `format` (shorthand, default `%H:%M`), `tone` |
| `ui.metric` | `name` (shorthand): `cpu`, `memory` or `battery` |
| `ui.metrics(names)` | a group of metrics, `{ "cpu", "memory", "battery" }` by default |
| `ui.group` | children in its list part, `mark` or `icon`, `tooltip`, `on_click`, `url` |

Every component also accepts `priority`, 0 to 100. Components default to 50
and a group's children inherit the group's priority.

`tone` is one of `neutral`, `muted`, `accent`, `success`, `warning` and
`danger`, and each adapter maps it to the theme's palette. Neutral components
use plain text and quiet shapes; colour is kept for attention.

`ui.clock` formats Telar's local time with `%H %M %S %I %p %d %e %m %y %Y %a
%A %b %B %%`; other bytes are copied. It needs no `every_ms`: the client
repaints on the next minute, or second when the format shows seconds, and only
while a clock is configured. `ui.metric` reads the runtime's latest sample; the
CPU metric draws the recent samples as a sparkline and turns `warning` at 90%
and `danger` at 98%, the battery at 20% and 10%. A host without a battery
omits it.

A group draws its mark or icon and its children with even spacing, and Telar
draws a hairline between a group and its neighbours. `tooltip` is a string or a
list of components, which may also use the panel blocks `heading`, `text`,
`meter_row`, `kv` and `divider`. The native app shows it above the group while
the pointer rests on it. `on_click` is a `telar.action` value run when the
group is clicked; `url`, an `http` or `https` address, is opened in the
browser instead. Only groups take a tooltip or a click, so wrap a single
component in `ui.group` to give it one.

When the bottom bar is narrower than its components, Telar reduces the
component with the lowest priority one step at a time, the later one on ties:
a meter first drops its track, any other component disappears, and a group
disappears once none of its children is visible. A `warning` tone adds 20 to a
component's priority while the bar is fitted and `danger` adds 40, so a
component asking for attention is the last to go. Top-level components that
did not fit are counted in a `+N` chip; clicking it lists them in a panel.

Legacy segment tables remain accepted as labels, and icons without text as
icons:

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
`provider-claude`, `provider-codex`, `provider-pi`, `app-terminal`,
`app-editor`, `app-git`, `agent-unknown`, `agent-working-0` through
`agent-working-3`, `agent-blocked`, `agent-ready`, `agent-done`,
`agent-failed`, `close`, `pane-fullscreen` and `telar-mark`. They follow the
configured Unicode or graphical icon theme.

A slot holds at most 64 components, 4096 bytes of text, 256 sparkline samples
and 32 actions, enough to open every panel and pick a configuration holds.
Text is UTF-8 without control characters. A render that returns more keeps
its highest-priority components that fit, each with its group, in their
order; the rest are left out and the limit notice names each bound passed
(`bars.max_bar_nodes`, `bars.max_bar_text_bytes`, `bars.max_bar_actions`,
`bars.max_samples`).

### Panels

`client.panels` names the panels a bar can open. A panel appears above the
component that opened it, closes on Escape, on a click outside it or on a
second click on its component, and renders its content only while it is open.

```lua
panels = {
  claude = telar.panel({
    title = "Claude usage",
    mark = "claude",
    width = 460,
    command = { "my-quota", "--json" },
    every_ms = 30000,
    render = function(ctx)
      local quota = telar.json.decode(ctx.output)
      return {
        ui.heading("On track"),
        ui.meter_row({ label = "Current session", detail = "Resets at 13:20", value = quota.session / 100, marker = 0.7 }),
        ui.actions({
          ui.button({ text = "Open in browser", url = "https://example.com/usage" }),
          ui.button({ text = "Refresh", action = telar.action.refresh_panel() }),
        }),
      }
    end,
  }),
}
```

`telar.panel` accepts `title`, `mark` or `icon`, `width` in logical pixels
(240 to 720, default 420), and either `command`, `timeout_ms` and `render`,
like `telar.bar.command`, or `render` alone, like `telar.bar.dynamic`. Without
`every_ms` a panel renders once each time it opens and on
`telar.action.refresh_panel()`. Panel names are 1 to 32 letters, digits, `-`
or `_`, and titles at most 128 bytes (a longer title is cut at a character).
A configuration holds at most 16 panels: past that it keeps the first 16 by
name, reports `panels.max_panels`, and an action naming one left out does
nothing.

A panel's content is any list of components plus these blocks:

| Block | Fields |
| --- | --- |
| `ui.heading` | `text` (shorthand), wrapped to three lines |
| `ui.text` | `text` (shorthand), `tone`, wrapped to three lines |
| `ui.meter_row` | `label`, `detail`, `value` 0..1, `marker` 0..1, `tone` |
| `ui.kv` | `key`, `value`, `tone` |
| `ui.callout` | `icon`, `text`, `detail`, one `button` |
| `ui.actions` | buttons in its list part, right aligned |
| `ui.button` | `text`, `action` or `url`, `primary` |
| `ui.divider` | none |

A panel holds at most 128 components, 16 KiB of text, 1024 sparkline samples
and 32 actions; a render that returns more keeps what fits by priority, like
a bar slot, and reports the `panels.*` limits. Its header shows the title,
the time of the last successful render and a close control. A failed render
keeps the last content and says so.

`telar.action.open_panel("name")` opens or closes a panel from a key binding
too; it appears above the bar component that opens the same panel.
`telar.action.close_panel()` and `telar.action.refresh_panel()` complete the
set. These actions are for configuration; plugin effects cannot return them.

### Picks

`client.picks` names lists a bar component or a key binding opens in the
command palette. The person filters the options by typing, chooses one with
Enter or a click, and Telar runs the pick's `on_select` command with the chosen
value, then reruns the bar sources and the open panel so they show the change.

```lua
picks = {
  thinking = telar.pick({
    title = "Thinking level",
    items = { "off", "minimal", "low", "medium", "high", "xhigh", "max" },
    on_select = { "my-agent-config", "thinking", "{}" },
  }),
},
bars = { bottom = {
  right = telar.bar.static(ui.group({ on_click = telar.action.pick("thinking"), ui.label("thinking") })),
  -- ...
} },
```

`telar.pick` accepts:

| Field | Meaning |
| --- | --- |
| `title` | shown in the palette; the pick's name by default |
| `items` | a list of options, or with `command` a function from the render context to that list |
| `command` | an argv that prints the options, one per nonempty line unless `items` parses its output |
| `on_select` | the argv to run with the choice; each argument that is exactly `"{}"` becomes the chosen value |
| `timeout_ms` | 100 to 60000, default 2000: how long `command` and `on_select` may each run, start to exit; picks run apart from the bar worker, so a slow one delays no bar |
| `refresh` | rerun the bar sources after `on_select` succeeds; `true` by default |

An option is a string, or a table with a `label` to show and search, a
`value` for `on_select` (the label by default) and a `detail` shown muted
beside the label and searched too. A list holds at most 4096 options and
256 KiB of text; labels and details are at most 128 bytes and values 512, all
printable UTF-8 on one line, and a value may also hold tabs. A list past
these keeps what fits: a longer label or detail is cut at a character, an
option whose value is longer is left out (a value is one argument, never
cut), options past the count or the text are left out, and the limit notice
names each `picks.*` limit passed. An `items`
function needs a `command`: it receives the context of
[a render callback](#dynamic-context), with the command's output in
`ctx.output`, and returns the list. A written `items` list is checked when
the configuration loads. Without `items`, each nonempty line of the output,
trimmed, is an option whose value is the line as printed; its label shows
tabs as spaces and is cut at a character past 128 bytes.

The list command runs when the pick opens, outside the client loop; the palette
shows "Loading…" until its options arrive. A command that fails, runs past its
timeout or prints control characters leaves the palette open with the reason.
A command that prints more than 256 KiB keeps its first whole lines and
reports `picks.max_pick_output_bytes`; what it prints on stderr past 4 KiB is
dropped. Opening another prompt closes the list, and options that
arrive after that are dropped.

`on_select` runs as an argv without a shell. Telar replaces only whole
arguments equal to `"{}"`, never text inside another argument and never the
program, so the chosen value is always exactly one argument, whatever
characters it holds. At least one `"{}"` must follow the program. When a
helper runs through `/bin/sh -c`, pass the value as a positional parameter
(`"$1"`) as the example below does; never build a script string from it. A
value may start with `-`, so helpers that take options should end them with
`--`. The command's output and errors go to `/dev/null`, so however much it
prints, a zero exit status is a success; a nonzero status, a signal or a
timeout shows a client diagnostic. A second choice while one still runs is
refused. Pick names follow the panel rules, and a configuration holds at most
16 picks, keeping the first 16 by name like panels. `telar.action.pick("name")` opens a pick from a binding as well;
plugin effects cannot return it. See [Pick list](flows/pick-list.md).

#### Example: Pi's default provider, model and thinking level

Pi reads `defaultProvider`, `defaultModel` and `defaultThinkingLevel` from
`~/.pi/agent/settings.json` when it starts, so writing them there changes what
`pi` starts with in every pane. This helper, saved as
`~/.config/telar/bin/pi-defaults` and made executable, writes one of them,
keeps the rest of the file and replaces it atomically. It keeps the file's
permissions but not its extended attributes:

```python
#!/usr/bin/env python3
"""Sets Pi's default provider, model or thinking level.

Usage: pi-defaults provider|model|thinking VALUE

A model written as provider/model sets both keys. The rest of
~/.pi/agent/settings.json is kept, and the file is replaced atomically with
its permissions; a symbolic link is followed and its target replaced.
"""
import json, os, sys, tempfile

KEYS = {"provider": "defaultProvider", "model": "defaultModel", "thinking": "defaultThinkingLevel"}
LEVELS = {"off", "minimal", "low", "medium", "high", "xhigh", "max"}

if len(sys.argv) != 3 or sys.argv[1] not in KEYS:
    sys.exit("usage: pi-defaults provider|model|thinking VALUE")
field, value = sys.argv[1], sys.argv[2]
if field == "thinking" and value not in LEVELS:
    sys.exit(f"unknown thinking level: {value}")

path = os.path.realpath(os.path.expanduser("~/.pi/agent/settings.json"))
try:
    with open(path) as source:
        settings = json.load(source)
        mode = os.fstat(source.fileno()).st_mode & 0o7777
except FileNotFoundError:
    settings, mode = {}, 0o600
if not isinstance(settings, dict):
    sys.exit(f"{path} does not hold a JSON object")

if field == "model" and "/" in value:
    settings["defaultProvider"], value = value.split("/", 1)
settings[KEYS[field]] = value

directory = os.path.dirname(path)
os.makedirs(directory, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".settings.")
try:
    with os.fdopen(descriptor, "w") as target:
        os.fchmod(target.fileno(), mode)
        json.dump(settings, target, indent=2)
        target.write("\n")
        target.flush()
        os.fsync(target.fileno())
    os.replace(temporary, path)
except BaseException:
    os.unlink(temporary)
    raise

folder = os.open(directory, os.O_RDONLY)
try:
    os.fsync(folder)
finally:
    os.close(folder)
```

The configuration lists providers and models from `pi --list-models`, whose
first line is a header and whose first two columns are the provider and the
model, and the thinking levels from a fixed list. The helper is reached
through `/bin/sh` only to expand `$HOME`; the choice arrives as `"$2"`, a
positional parameter, never as script text:

```lua
local telar = require("telar")
local ui = telar.ui

local function pi_defaults(key)
  return {
    "/bin/sh", "-c", 'exec "$HOME/.config/telar/bin/pi-defaults" "$1" "$2"',
    "pi-defaults", key, "{}",
  }
end

-- `pi --list-models` rows: provider, model, then sizes and capabilities.
local function pi_models(ctx)
  local options = {}
  for provider, model in ctx.output:gmatch("\n(%S+)%s+(%S+)") do
    options[#options + 1] = { label = model, detail = provider, value = provider .. "/" .. model }
  end
  return options
end

local function pi_providers(ctx)
  local options, seen = {}, {}
  for provider in ctx.output:gmatch("\n(%S+)") do
    if not seen[provider] then
      seen[provider] = true
      options[#options + 1] = provider
    end
  end
  return options
end

return telar.config({
  api_version = 2,
  client = {
    picks = {
      pi_provider = telar.pick({
        title = "Pi provider",
        command = { "pi", "--list-models" },
        timeout_ms = 5000,
        items = pi_providers,
        on_select = pi_defaults("provider"),
      }),
      pi_model = telar.pick({
        title = "Pi model",
        command = { "pi", "--list-models" },
        timeout_ms = 5000,
        items = pi_models,
        on_select = pi_defaults("model"),
      }),
      pi_thinking = telar.pick({
        title = "Pi thinking level",
        items = { "off", "minimal", "low", "medium", "high", "xhigh", "max" },
        on_select = pi_defaults("thinking"),
      }),
    },
    bars = { bottom = {
      left = telar.bar.tabs(),
      right = telar.bar.command({
        command = { "/bin/sh", "-c", 'cat "$HOME/.pi/agent/settings.json" 2>/dev/null || echo "{}"' },
        every_ms = 30000,
        render = function(ctx)
          local ok, pi = pcall(telar.json.decode, ctx.output)
          pi = ok and pi or {}
          return {
            ui.group({ mark = "pi", on_click = telar.action.pick("pi_provider"), ui.label(pi.defaultProvider or "provider") }),
            ui.group({ on_click = telar.action.pick("pi_model"), ui.label(pi.defaultModel or "model") }),
            ui.group({ on_click = telar.action.pick("pi_thinking"), ui.label({ text = pi.defaultThinkingLevel or "medium", tone = "muted" }) }),
          }
        end,
      }),
    } },
  },
})
```

Choosing a model writes both keys, since its value is `provider/model`. Telar
runs `pi` with the window's `PATH`; write its absolute path, such as
`/opt/homebrew/bin/pi`, when the window does not find it. The same shape
serves any agent that reads its defaults from a file.

### Dynamic context

A dynamic, command or panel render callback receives one immutable table. Tab
indices are one-based in Lua.

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

`telar.json.decode(text)` turns a JSON document of at most 1 MiB into Lua
tables, with `null` as `nil`, and raises a Lua error for invalid JSON. It is
pure: it reads no file and opens no connection.

`every_ms` defaults to 1000 and must be between 100 and 3,600,000. Each source
owns one deadline. If a client is delayed, expired ticks collapse into one
evaluation instead of replaying every missed value. Lua evaluation keeps the
same instruction, memory and wall-time containment as other client
callbacks. A failure leaves the last valid content in place and publishes a
bounded client diagnostic.

Commands contain 1 to 32 arguments and at most 4096 argument bytes. Telar
executes the argv directly, without a shell, and inherits the client's process
environment and working directory. `timeout_ms` defaults to 2000 and must be
between 100 and 10000, since bar and panel commands share one worker and a
slow one delays the others; it bounds the whole run, from start to exit,
however the command prints. A command runs in its own process group: one that exits
in time may leave background work running, while one that passes its
timeout is stopped with its group, TERM first and KILL 200 ms later. Output passed to a `render` callback may hold several
lines, up to 64 KiB of UTF-8 without control characters other than tab and
newline, so a helper can print JSON. Without `render`, stdout must be one
display line of at most 512 bytes. Output past its bound keeps its first
whole lines (its first 512 bytes, cut at a character, for one line), is
stopped there rather than left printing until its timeout, and reports
`bars.max_command_output_bytes` or `bars.max_text_bytes`. Stderr
past 4096 bytes is dropped and never fails the command. Bar and
panel commands share one worker, and another elapsed tick records only one
pending rerun. Reloading the configuration discards a completion from the
previous generation.

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
The keymap holds 256 bindings: past that it keeps the first configured ones,
then the defaults that fit, and reports `config.max_bindings`; the window
always starts. `telar.action.command_tab({ command = argv, label = text })`
takes an argv of up to 32 arguments and 4096 bytes, like a bar command, and a
label of at most 32 bytes. The commands a configuration's bindings and
static components open share 80 KiB (768 of them); a binding whose command
passes one of these is left out and its limit reported, and a command is
never cut. What renders and callbacks return shares 32 KiB of recent rows,
cleared between renders when half is used; a button whose command was
cleared says so and renders the bars again.
`telar config check` compiles the merged keymap and reports conflicts between
configured bindings. `client.input.sequence_timeout_ms` applies only to partial
global sequences; prefixed sequences do not expire.

`telar.bind` and `telar.bind_global` accept a semantic built-in action, a
constructor such as `split_pane`, `focus_pane`, `select_tab`,
`resize_pane`, `resize_sidebar`, `scroll_pane`, `select_tab_offset`, `move_tab`, or `plugin`, or a Lua callback. The
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

`telar.action.leave_worktree()` returns from a worktree's tab to the project
workspace the worktree hangs from; outside a worktree it does nothing. The
default binding is `prefix`, then `u`.

`telar.action.scroll_pane({ direction = ... })` accepts `"up"` or `"down"` and
applies one wheel step to the focused pane without entering copy mode. The
default bindings are `prefix`, then `-` to scroll up, and `prefix`, then `=`
to scroll down. For holding a key, use a modified chord that the host reports
with physical repeat events, such as these global bindings:

```lua
telar.bind_global({ "alt+up" }, telar.action.scroll_pane({ direction = "up" }))
telar.bind_global({ "alt+down" }, telar.action.scroll_pane({ direction = "down" }))
```

The first step is immediate; host auto-repeat then drives at most one step
every 100 ms. Excess repeats are discarded, not queued. Releasing the key,
another key press, pointer input, paste, configuration reload or a changed
target cancels the hold. Lua callbacks and other actions do not gain
physical-repeat execution.

A prefixed binding can also repeat its final chord when the host reports its
physical lifecycle, without re-entering the prefix. Telar requests Kitty
keyboard flags 7, which leave plain text keys such as the default `-` and `=`
suffixes as text. Those defaults still require the prefix for each step.
Legacy hosts that report only presses keep ordinary binding behavior;
Telar does not infer a held key or start a synthetic repeat timer.

The action follows the same policy as the wheel: send an SGR wheel report when
the application tracks it, send three cursor keys at the live bottom when
alternate-screen scroll is enabled, or move the retained viewport by three
rows otherwise. The application decides how far an SGR wheel report scrolls.
The target is always Telar's focused pane, never the pane under the pointer.
Synthetic reports use the first content cell, buttons 64/65 and no modifiers;
pixel reports use that cell's center. Neither the pointer nor the terminal
cursor chooses the position, so this does not target an application's focused
internal split. Missing targets and unchanged viewport offsets have no effects.
Normal typing or paste returns a scrolled viewport to live output.

Like other native actions, invoking `scroll_pane` from copy mode first exits
copy mode and restores its entry viewport, then applies the wheel step. The
action is available to client Lua bindings and callbacks, but plugin worker
effects reject it.

`telar.action.copy_mode()` enters the focused pane's scrollback. Its default
binding is `prefix`, then `[`. In copy mode, the mouse wheel scrolls three rows
per notch while it is over the target pane and other mouse actions are ignored.
Outside copy mode, applications that own mouse reporting keep receiving wheel
events, and an alternate-screen application with alternate-scroll enabled
receives cursor keys instead. Normal pane input returns the viewport to the
bottom.

`telar.action.history_palette()` opens command-history search. Its default
binding is `prefix`, then `/`. Bind it with `telar.bind_global` when it should
open without the prefix.

`telar.action.next_machine()` and `telar.action.previous_machine()` switch
the whole window to the next or previous enabled machine, wrapping around.
`telar.action.machine_picker()` opens the command palette on the window's
machines, which typing `:` in the palette also does; there Enter shows a
machine, Shift+Enter enables or disables it, Ctrl+R renames it and Ctrl+D
removes it. `telar.action.add_machine()` asks for a new machine's label and
SSH destination. Each change is written to `machines.json`. They have no
default binding, and plugins cannot run them. See
[Machine presentation](flows/machine-presentation.md).

`telar.action.path_picker()` opens a fuzzy finder over the files and
directories under the focused pane's directory, anchored at its cursor. Enter
pastes the chosen path relative to the pane's directory, Alt+Enter pastes it
absolute, Tab browses the selected directory and Shift+Tab its parent. Up and
Down, or Ctrl+K and Ctrl+J, move the selection; Ctrl+K and Ctrl+J move it in
every list prompt. Its default binding is `prefix`, then `f`.

Copy mode accepts `h`, `j`, `k`, `l` and the arrow keys, `w`, `b`, `e`, `{`,
`}`, `0`, `^`, `$`, `g`, `G`, Page Up, Page Down, Ctrl-B, Ctrl-F, Ctrl-U, and Ctrl-D.
Press `v` or Space for a character selection, `V` for a line selection, then
`y` or Enter to copy through OSC 52. Escape first clears an active selection;
a second Escape, or `q`, leaves copy mode and restores the entry viewport.
Press `o` over a textual `http://`, `https://`, or `file://` URI to open it
without leaving copy mode. A left click opens the same URI outside copy mode.
Web URIs use the operating system's default handler. Local file URIs open a
new tab with `$EDITOR` as the executable and the decoded path as its only
argument; Telar does not evaluate `$EDITOR` through a shell.
The bottom bar replaces metrics and tabs with these movement, selection, copy,
and exit hints until copy mode ends. Pressing the configured prefix temporarily
replaces them with the prefix-mode hints.

`telar.action.toggle_pane_fullscreen()` makes the focused pane occupy the whole
tab inside its own border, and the tab bar marks the tab with a fullscreen
icon. The top border lists the tab's panes in display order and highlights the
focused pane. Long labels are truncated; when the strip overflows, the focused
pane stays visible. In fullscreen, left/right focus selects the previous/next
pane without wrapping, and up/down focus does nothing. These rules apply to
pane-focus actions, not arrow keys forwarded to the child. With Kitty graphics
support and RGB label colors, pane labels use smaller embedded JetBrains Mono
Regular text. The selected pill is 75 percent of the cell height and centered
on the border; workspace labels and pane contents keep their usual size.
While graphics are pending, unavailable or cannot display a glyph, the labels
use normal terminal text without bold and selection stays rectangular.

The client retains the tiled layout and its split ratios. Invoking the action
again restores that geometry and spatial navigation, keeping the last selected
pane focused. The default binding is `prefix`, then `z`. A tab with one pane
can also enter fullscreen, including its border and label. Creating another
pane keeps fullscreen active and focuses the new pane; closing back down to
one pane does not exit the mode. Toggle again to leave fullscreen and restore
borderless content when only one pane remains.

`telar.action.toggle_workspace_list()` records a collapse preference in the
client layout (default binding `prefix`, then `w`) that the window does not
use: it shows up to three consecutive workspaces whenever
they fit, centered on the active one except at either end. Narrow windows
show the active workspace. Overflow counters show how many remain hidden and
select the nearest hidden workspace; global workspace numbers do not change.

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

Evaluating the configuration may use 16 MiB of Lua memory and one million Lua
instructions; a key callback and a bar or panel render may use 100,000
instructions, and a pick's `items` function, which runs once when the pick
opens, one million. Pattern matching,
`string.find` and `table.sort` count their steps as instructions, so one
backtracking search or large sort spends the same budget. The instruction
count is the budget, so whether a file loads does not depend on how busy the
machine is. A wall-clock deadline of 2 s for the file and 100 ms for a
callback or render (1 s for a render in a debug build) is checked between
instructions and those steps; it stops a run of
costly instructions, such as repeated `string.rep` over megabytes, but not a
single other call, which the memory limit bounds to about 25 ms.

The client watches the main file, loaded local modules, configured plugin
trees, and the trust store. A change builds a complete replacement generation.
Theme, sidebar, keymap, callbacks, plugin registry, and grants swap only after
all validation succeeds. A failure leaves the previous generation active and
shows the error as a notice in the window and on stderr. Closure
state is intentionally lost on reload.
The client model records the accepted generation, sidebar and pane-gap state;
the presenter observes that version and paints the new appearance on its paced
frame. The ownership and failure order is mapped in
[`flows/config-reload.md`](flows/config-reload.md).

The runtime evaluates the same file in a disposable VM and retains only typed,
validated values. No Lua state or closure enters the runtime process.
`runtime.history.path` is resolved relative to the directory containing
`config.lua`; its parent directory must already exist. `runtime.proxy` accepts
`enabled`, `ca_dir`, `capture`, and `intercept_hosts`. ProxyTLS and exchange
capture are disabled by default. A
relative `ca_dir` is also resolved beside `config.lua`; Telar creates it
owner-only and stores its private CA and derived trust bundle there with
owner-only file permissions. `intercept_hosts` accepts at most 256 exact DNS
hostnames, leading wildcard rules such as `*.example.com`, or the global `*`
rule within a 64,768-byte budget. It is empty by default, so an enabled proxy
intercepts nothing until you name hosts. Telar canonicalizes case, sorts
the set, and removes duplicates when the runtime starts. A leading wildcard
matches proper subdomains but not the bare suffix; `*` matches every hostname.
Partial labels such as `*example.com` and embedded wildcards are rejected.
Every connection still requires the proxy secret, which Telar writes to
`proxy-secret` in `ca_dir` on the first start and puts in each pane's
`HTTPS_PROXY`; delete the file to rotate it. Each runtime also remembers its
listener port there, in its own `proxy-port-<key>` file, so runtimes that
share `ca_dir` keep separate ports. A connection outside the
configured scope passes through the authenticated CONNECT listener, but its
TCP payload is forwarded opaquely and is not captured.

System trust is not a configuration side effect. Run `telar proxy trust
install|uninstall|status` explicitly. If `ca_dir` is custom, pass the same
absolute path with `--ca-dir`. Linux installation also requires either
`--linux update-ca-certificates` or `--linux trust`. The installed authority is
separate from the private CA, expires after 30 days, and rotates when the
server starts with less than one day remaining.

`runtime.proxy.capture` accepts `enabled`, `max_part_bytes`,
`max_exchange_bytes`, `max_total_bytes`, and `join_timeout_ms`. The byte limits
must satisfy `max_part_bytes <= max_exchange_bytes <= max_total_bytes`; all
limits and the timeout must be positive. `max_part_bytes` and
`max_exchange_bytes` may be at most 64 MiB, `max_total_bytes` at most 1 GiB
and `join_timeout_ms` at most one hour. Captured heads and de-framed bodies
are bounded independently; request and response each get half of
`max_exchange_bytes`. A full queue or exhausted quota drops capture data
without delaying or changing proxied traffic, and the limit notice names the
bound that cut it. Response decompression runs off the runtime's event loop,
only while a tap plugin listens, and is capped by `max_part_bytes`.
Until a trusted tap plugin is configured, completed captures are consumed only
for metrics and are not persisted. Runtime tap workers are created only at
server startup, so restart the runtime after changing a tap package or its
grants.

Explicit server CLI graphics limits still override the Lua values.
Runtime-owned settings take effect when the long-lived runtime starts; restart
that runtime to apply a changed runtime profile.

No proxy callback is accepted directly in `runtime.proxy`. Enabled plugin
packages declare `on_exchange`; the runtime converts them to isolated worker
specifications and retains no Lua state or closure. Bodies remain streaming on
the relay path and become available to the worker only as bounded captured
snapshots. See [`proxy-tls.md`](proxy-tls.md) and
[`plugins.md`](plugins.md) for the capture and authority contracts.
