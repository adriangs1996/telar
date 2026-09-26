# Native bar and panels

Status: implemented on `feat/native-bar`; reference in
[configuration](../configuration.md#bars) and
[configurable bars](../flows/configurable-bars.md). Decided with Adrian on 2026-09-26
over the "Telar status bar" canvas (antes y después, degradación, vocabulario,
panel de detalle).

## Problem

Bar content is a list of text segments with a color. Users reach for Nerd Font
glyphs and `|` separators to fake structure, and both adapters paint the result
as cells. Nothing in the bar can be hovered or clicked, and a widget has no way
to show more than one line.

## Decisions

1. Lua composes a closed vocabulary of components; Telar owns how they look.
   No drawing API is exposed.
2. Components carry a semantic tone (`neutral`, `accent`, `success`,
   `warning`, `danger`), not a color. Legacy segment tables keep working as
   `label` components with their style.
3. Telar lays the bar out: spacing, hairline separators between top-level
   components, and degradation by priority when the bar does not fit.
4. A click runs a `telar.action.*` value. `telar.action.open_panel` opens a
   panel anchored to the component that was clicked.
5. A panel is declared once in `client.panels`, rendered by Lua from its own
   source (`command` or `dynamic`) only while it is open, and built from block
   components.
6. `telar.json.decode` is available to configuration callbacks.
7. Buttons and groups may open an `http(s)` URL through the existing link
   opening worker.

## Vocabulary

Inline components, valid in bar slots, group children, tooltips and panels:

| Component | Fields |
| --- | --- |
| `label` | `text`, `tone`, legacy `fg`/`bg`/`bold`/... |
| `icon` | `name` (built-in icon) or `glyph` (one grapheme), `tone` |
| `mark` | `name`: `claude`, `codex`, `pi`, `telar` |
| `meter` | `value` 0..1, `label`, `text` (overrides the percentage), `marker` 0..1, `tone` |
| `sparkline` | `values` (numbers, at most 32), `max`, `tone` |
| `badge` | `text`, `tone` |
| `clock` | `format` (strftime subset); formatted by Telar, no Lua tick |
| `metric` | `name`: `cpu`, `memory`, `battery`; formatted by Telar from runtime metrics |
| `group` | children, `mark`/`icon`, `tooltip` (string or components), `on_click` action, `url` |

Every component accepts `priority` (0..100, default 50; group children inherit
the group's). A `warning` tone adds 20 and `danger` adds 40 while the bar is
fitted.

Block components, valid in panels:

| Component | Fields |
| --- | --- |
| `heading` | `text` |
| `text` | `text`, `tone` |
| `meter_row` | `label`, `detail`, `value`, `marker`, `text`, `tone` |
| `kv` | `key`, `value` |
| `callout` | `icon`/`glyph`, `text`, `detail`, one `button` |
| `actions` | buttons, right aligned |
| `button` | `text`, `action` or `url`, `primary` |
| `divider` | none |

## Degradation

Top-level components share the bottom bar. While the content is wider than the
bar, Telar reduces the component with the lowest effective priority by one
step, the later one on ties:

- `meter`: full, then value only, then hidden;
- any other leaf: shown, then hidden;
- `group`: hidden only when none of its children is visible.

Hidden top-level components are counted in a `+N` chip that opens the
overflow list. The fitting is a pure function in the model; each adapter
supplies its widths (pixels in the GUI, cells in the TUI).

## Ownership and bounds

- Content is a bounded value in `model`: 32 nodes, 1 KiB of text, 64 samples
  and 4 actions per bar slot; 64 nodes, 4 KiB, 64 samples and 8 actions per
  panel.
- The panel is client state: which panel is open, its anchor, its content,
  its status and the time of its last update. It lives in `model.bars` and
  shares `Version.bars`.
- The open panel is one more position of `BarUpdatesState`, so it shares the
  bar deadline worker and the single command process. A closed panel has no
  deadline.
- Command output is owned by the completion, at most 64 KiB, UTF-8 with no
  control bytes other than tab and newline. Output without a render callback
  must still be one display line.
- Clicks and hover reach the client as view interactions; the adapters never
  call Lua.

## Slices

1. Model: nodes, content, fitting, clock formatting, CPU samples, panel state.
2. Client: Lua constructors and parser, `client.panels`, `telar.json`, panel
   scheduling, actions, clicks, output ownership.
3. GUI: component painter, fitting, hover tooltip, overflow, panel widget.
4. TUI: cell painter, fitting, panel box.
5. Docs and an example configuration that recreates the canvas with data a
   user supplies.
