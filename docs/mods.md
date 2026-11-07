# Mods

A mod draws part of Telar's window with Lua: the top bar, the bottom bar, the
tabs, the pane headers, the activity cards, or any piece of them. Telar keeps
drawing everything a configuration leaves out with its own QML, so a mod can
replace one status chip and nothing else.

A mod is a folder of Lua files. It is not a [plugin](plugins.md): plugin code
runs in a separate, sandboxed worker and never inside the client, while a mod
has to run inside the client to answer as fast as the window redraws. A mod has
the same authority as your `config.lua`, so read one before you use it.

## Try one

Copy [`docs/examples/mods/stack-tabs`](examples/mods/stack-tabs/init.lua) to
`~/.config/telar/mods/stack-tabs/` and add its slots to your configuration:

```lua
local telar = require("telar")

return telar.config({
  api_version = 2,
  client = {
    components = require("mods.stack-tabs"),
  },
})
```

`require("mods.stack-tabs")` loads `mods/stack-tabs.lua`, or
`mods/stack-tabs/init.lua` when that file does not exist, beneath the directory
holding `config.lua`. Saving any file the configuration loaded reloads it, so
edit the mod with Telar open and watch the change.

To combine mods, merge their tables:

```lua
local components = {}
for _, mod in ipairs({ require("mods.stack-tabs"), require("mods.cards") }) do
  for slot, render in pairs(mod) do components[slot] = render end
end
```

## Slots

`client.components` maps slot names to functions. Each function receives the
render context, the same table bar renders receive, and an item describing what
it draws, and returns an element.

| Slot | Draws | Item |
| --- | --- | --- |
| `top_bar` | the whole top bar, right of the window buttons | window |
| `bottom_bar` | the bottom bar's components; prefix mode, TLS and diagnostics stay native | window |
| `tab` | one tab, inside its native selection and drag | tab |
| `pane_header` | one pane's header and its buttons | pane |
| `agent_card` | one activity card | agent |
| `tab_cards`, `tab_title`, `tab_path`, `tab_activity` | a piece of the default tab | tab |
| `pane_mark`, `pane_program`, `pane_context`, `pane_status`, `pane_progress`, `pane_actions` | a piece of the default pane header | pane |
| `agent_mark`, `agent_title`, `agent_project`, `agent_status` | a piece of the default card | agent |

A piece slot draws in the box the default piece had. When the whole component
slot is set, its pieces are drawn only where it places them with `ui.builtin`.

Items are plain tables. Text that comes from a terminal, such as titles and
paths, arrives without control characters.

```lua
-- window
{ workspace = "telar", machine = "laptop", tab_count = 3, sidebar_visible = true }
-- tab
{ index = 1, key = "4", title = "nvim", label = "nvim", path = "~/src/telar",
  application = "nvim", selected = true, attention = false,
  panes = { { key = "12", program = "nvim", focused = true, attention = false } } }
-- pane
{ id = "12", index = 1, program = "claude", context = "~/src/telar", focused = true,
  fullscreen = false, images_paused = false, needs_attention = false, progress = "",
  agent = { status = "blocked", blocked_reason = 1 } }
-- agent
{ key = "...", title = "Fix the build", project = "telar", detail = "", provider = "Claude",
  status = "working", selected = false, compact = false, depth = 0,
  plan = { done = 2, total = 5, step = "Run tests" } }
```

`status` is one of `unknown`, `working`, `blocked`, `ready`, `failed` and
`done`.

## Elements

A slot function returns one element, a list of elements (drawn as a row) or a
string (drawn as a label). Every constructor takes a table; the ones with a
shorthand also take their main field alone, as in `ui.label("text")`.

| Element | Fields |
| --- | --- |
| `ui.row`, `ui.column` | children in the list part; `gap`, `align` (`start`, `center`, `end`, `stretch`) across, `justify` (`start`, `center`, `end`, `between`) along |
| `ui.stack` | children drawn over each other; `align` places them vertically, `justify` horizontally, `x` and `y` offset each one |
| `ui.spacer` | takes the room left in its row or column |
| `ui.label` | `text` (shorthand), `size` (`title`, `body`, `small` or pixels), `bold`, `italic`, `color`, `tone`, `max_lines` |
| `ui.icon` | `name` (shorthand, a [bar icon](configuration.md#components)) or `glyph`; `size`, `color`, `tone` |
| `ui.mark` | `name` (shorthand): `claude`, `codex`, `pi` or `telar` |
| `ui.badge` | `text` (shorthand), `tone`, `color` |
| `ui.tile` | `program` (shorthand): the program's application tile, as tabs draw it; `size` |
| `ui.canvas` | `width`, `height`, `ops`, `label` for screen readers |
| `ui.builtin` | `name` (shorthand): a native piece, listed below |
| `ui.elapsed` | `since` (shorthand, Unix seconds): `12s`, `3m`, `2h`, `1d` |
| `ui.clock` | `format` (shorthand, default `%H:%M`), with the [bar clock's](configuration.md#components) conversions |

Every element also takes these fields; lengths are logical pixels:

| Field | Meaning |
| --- | --- |
| `id` | identity across renders; an element with an `id` keeps its place and can ease |
| `width`, `height`, `min_width`, `max_width`, `min_height`, `max_height` | size; without them an element takes its content's size |
| `grow` | share of the room left along a row or column |
| `align_self` | overrides the container's `align` for this element |
| `padding` | one length, `{vertical, horizontal}` or `{top, right, bottom, left}` |
| `background`, `border` (`color` or `{color, width}`), `radius`, `shadow`, `clip` | the box |
| `x`, `y`, `rotation` (degrees), `scale`, `opacity`, `z` | pose, applied after layout |
| `transition` | milliseconds, or `{duration, easing}` with `ease_out`, `linear` or `ease_in_out` |
| `on_click` | a `telar.action` value or a function |
| `url` | an `http` or `https` address opened on click |
| `tooltip`, `hover` (`{background}`) | pointer feedback |

Colors are theme roles (`accent`, `text`, `subtext0`, `green`, `yellow`, `red`,
…), `#RRGGBB`, `#RRGGBBAA`, or terminal palette indices. `tone` is `neutral`,
`muted`, `accent`, `success`, `warning` or `danger`.

When a row has less room than its children ask for, the children without a set
size shrink and their text ends in an ellipsis.

### Built-in pieces

`ui.builtin` places Telar's own QML piece, with its animation and behaviour,
inside a mod's layout:

- `tab_cards`, `tab_title`, `tab_path` and `tab_activity` in a `tab`.
- `pane_mark`, `pane_program`, `pane_context`, `pane_status`, `pane_progress` and `pane_actions` in a `pane_header`.
- `agent_mark`, `agent_title`, `agent_project` and `agent_status` in an `agent_card`.
- `sidebar_toggle`, `workspace_identity`, `project_switcher`, `tabs`, `palette_button` and `new_tab` in the `top_bar`; give `tabs` a `grow` or a `width`.
- `metrics`, `bar_left`, `bar_center` and `bar_right` in the `bottom_bar`. The last three show the [`bars.bottom`](configuration.md#bars) sources.

### Canvas

`ops` is a list of drawing steps run in order. A path collects shapes until
`fill` or `stroke` paints it:

| Step | Values |
| --- | --- |
| `{"move", x, y}`, `{"line", x, y}` | start a subpath, add a line |
| `{"curve", c1x, c1y, c2x, c2y, x, y}`, `{"quad", cx, cy, x, y}` | Bézier curves |
| `{"arc", cx, cy, r, from, to}` | an arc in degrees, clockwise from twelve o'clock |
| `{"rect", x, y, w, h}`, `{"round_rect", x, y, w, h, r}`, `{"circle", cx, cy, r}` | closed shapes |
| `{"path", "M0 0 L8 8 Z"}` | SVG path data: `M L H V C Q Z`, absolute or relative |
| `{"close"}` | close the subpath |
| `{"fill", color}`, `{"stroke", color[, width]}` | paint and start a new path |
| `{"width", w}`, `{"cap", "round"}`, `{"join", "round"}`, `{"alpha", a}` | stroke and paint state |
| `{"translate", x, y}`, `{"rotate", degrees}`, `{"scale", s[, sy]}`, `{"save"}`, `{"restore"}` | transform |

A canvas repaints only when its steps change, never on its own.

## Clicks

`on_click = telar.action.toggle_sidebar()` runs a built-in action like a key
binding. A function runs on the Lua thread and may return actions; afterwards
every slot renders again, so a mod can keep state in its own variables:

```lua
local expanded = false

function M.agent_card(ctx, agent)
  return ui.column({
    on_click = function() expanded = not expanded end,
    ui.label({ text = agent.title, bold = true }),
    expanded and ui.label({ text = agent.detail, max_lines = 4 }) or ui.spacer(),
  })
end
```

A click runs the action the element was rendered with, even if the table it
came from changed since.

## Motion

An element with an `id` and a `transition` eases between renders: when its
position, rotation, scale or opacity changes, Telar animates the change on the
window's own clock, without running Lua per frame.
[`stack-tabs`](examples/mods/stack-tabs/init.lua) uses this to lift the focused
pane's tile.

## When a slot renders

A slot instance renders when its item changes, when the configuration reloads,
when a click function runs, and when the theme changes. Nothing renders while the
window only redraws, so a mod costs nothing while a terminal scrolls. Time does
not change items: use `ui.clock` and `ui.elapsed`, which tick natively.

Renders run on the client's Lua thread, never on the window's. Until an
instance's first render arrives, and after one fails, Telar shows the default
piece. Three failures in a row make that instance fall back to QML until the
configuration reloads, and the window shows the error.

## Limits

A render may run 50 million Lua instructions within 1 s and use the
configuration's 256 MiB of Lua memory. One render returns at most 4096
elements, 256 KiB of text, 4096 canvas steps, 1024 actions and 1024 click
functions, nested at most 32 deep. The [configuration
environment](configuration.md#environment-and-reload) applies: no `io`, no
process or network access, and `require` only beneath the configuration
directory.

## Examples

[`docs/examples/mods`](examples/mods) holds a mod per component that redraws the
default with elements and built-in pieces, as a starting point to copy and
change, and `stack-tabs`, a tab with its own animated card stack.
