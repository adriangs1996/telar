# GUI visual language

Baseline: telar `64469065` (main), 2026-09-14. Decided by Adrian in the
Lavish review of 2026-09-14 over `.lavish/gui-visual-language.html` (kept as
the visual record; this file is the implementation reference). References
studied: T3 Code, cmux, herdr, Zed, Warp 2.0, Conductor, Ghostty, Claude Code
Desktop, Codex app, Cursor. Every claim about telar below was verified in the
tree at the baseline commit.

Status: implemented on `feat/gui-visual-language` (six slices, one branch
each under `feat/gui-vl-*`), validated in
`docs/validation/gui-visual-language/final.md`. Slices 7 (chrome text sizes) and 8 (sprites) in progress. Open
follow-ups: branch for worktree tabs, Wayland pass over the merged branch.

## Thesis

The terminal grid stays cells. Everything around it stops pretending to be
cells: native chrome is drawn with quads, measured in logical pixels where it
matters, and communicates one thing: which agent needs the person and where
it is. One color per meaning, the same in sidebar, tab, pane and toast.
Nothing blinks forever.

## Decisions

| # | Decision |
| --- | --- |
| 1 | Tabs live in their own strip under the top bar, with no line between the two. The TUI keeps its August decision (tabs bottom right); the GUI diverges here. |
| 2 | Panes keep straight 1px borders, no gaps, no rounded corners. The attention ring is drawn inside the pane rectangle. |
| 3 | Chrome text uses an embedded proportional face; the terminal's monospace face stays for commands, paths, branches and key hints. Face: IBM Plex Sans (OFL), Regular and SemiBold, static files. |
| 4 | The agent card has three rows in the structure of T3 Code's `card` row: project row, title row, last-event row with status icon and provider mark. No location row, no branch row. |
| 5 | The sidebar has no section headers or dividers. It is one list ordered by attention: needs input (`blocked`, `failed`) > working > ready-unseen (`done`) > idle (`ready`) > `unknown`, then most recent status change first. |
| 6 | Status is an icon in its color, not a word: `⚠` permission, `?` question, `◌` working (with elapsed time), `✓` done unseen, `✕` failed, `·` idle. The word goes in the tooltip and the pane header. |
| 7 | The top bar right side shows the selected workspace's location (worktree or cwd, with branch). No search field; the palette opens by key. The pane header no longer shows the cwd. |
| 8 | The status bar shows the mode chip and prefix hints only. |
| 9 | Agent mode is out of scope: it will be a specialized pane, not a mode that replaces the chrome. `docs/plans/agent-mode.md` stays as vocabulary and keymap reference. |
| 10 | Creating a context (workspace) asks for two fields: name and working directory, with path autocompletion. |
| 11 | System metrics are a Lua bar slot in the sidebar footer, `metrics` by default. Same slot mechanism as the bottom bar. |
| 12 | The command palette covers actions and agents/panes. History keeps its own modal with its inspector. |
| 13 | The native titlebar is hidden by default on macOS and fused with telar's top bar; on Wayland the compositor decoration is respected. |
| 14 | Osaka Jade becomes a built-in theme and the default. |

## Principles

- **P1 Cells inside, pixels outside.** The terminal grid is untouchable. Bars
  have the height they need, not one row; panes keep their 1px borders.
- **P2 One color per meaning.** blocked = `yellow`, working = `teal`,
  done = `green`, failed = `red`, idle = `overlay1`. The same color in the
  card icon, the tab dot, the pane ring and the toast border. Nothing else
  uses those colors.
- **P3 Attention is ordered, not shouted.** One comparator (decision 5) for
  the sidebar, for "next that needs me" and for toast order. No perpetual
  shimmer: the working pulse is 6 steps over 2 s.
- **P4 A row answers what, where and what it wants.** Project, title, last
  event with status. Tokens drop from right to left when the row does not
  fit.
- **P5 One palette, one theme.** The 16 roles of
  `src/client/appearance/Palette.zig` stay. New chrome derives surfaces from
  those roles; no second theme system.
- **P6 Nothing costs a frame.** Fixed buffers, `HitMap` grown by constant,
  quads reserved at geometry time, animation by frame counter. A decoration
  that allocates on the interactive path does not ship.

## Current state (facts)

- Regions are cells: sidebar full-height left column, top bar 1 row, bottom
  bar 1 row (`src/gui/chrome/Regions.zig`). Sidebar min/default 42 columns
  (`src/client/layout/sidebar.zig:5-6`).
- `chrome/Canvas.zig` draws `fill`, `text`, `border` clipped to a cell rect;
  text advances by grapheme width through the shared atlas.
- `render/Quad.zig` is the only primitive: an `extern struct` of position,
  size, uv and straight RGBA, mirrored field for field by `telar_gui_quad` in
  `macos/window.m` and by the Vulkan backend. Shaders in `src/gui/shaders/`.
- `text/FontSet.zig` owns at most three faces (configured, embedded
  JetBrains Mono, embedded Nerd Symbols) sharing one 1024² alpha atlas page.
- `chrome/Sidebar.zig` prints the placeholder header `minions`;
  `AgentCard.zig` draws three text rows with a flat background.
- The agent snapshot entry (`src/client/agents/Agent.zig`) carries key,
  location, pane index, workspace and tab labels, session title, cwd label,
  provider name, display name, icon, attachments, provider and status. No
  blocked reason, no last event, no age.
- `CreateWorkspace` (`src/core/schema/messages/CreateWorkspace.zig`) already
  carries `name` and `launch` with the cwd; the client only asks for the name
  (`src/client/model/name_prompt.zig`, target `create_workspace`).
- Bottom bar slots are Lua-configured (`bar_regions.zig`, `BarContent.zig`,
  `Bars.zig`); `metrics` is one slot kind.
- Built-in themes: vesper (default), catppuccin, tokyo_night, terminal
  (`src/client/appearance/theme_support.zig`). Osaka Jade exists only as
  `dev/osaka-jade.lua`.
- `gui.window.titlebar` defaults to `true` (`docs/configuration.md`).
- Budgets: `HitMap.capacity` = 708; `frame_budget.zig` reserves quads for
  cells + one 140×30 modal + 4 toasts of 48×4; 60 Hz by
  `host_ports.frameIntervalNs`; one `u8 sidebar_animation_frame` drives all
  animation.

## Tokens

| Token | Value | Notes |
| --- | --- | --- |
| chrome.font | IBM Plex Sans Regular/SemiBold, embedded | Single-line labels only; HarfBuzz advances, no paragraph layout. Mono for commands, paths, branches, kbd. |
| chrome.size | roles title ×1.0, body ×0.87, small ×0.73 of the terminal size, times `gui.chrome.scale` | Card title SemiBold. The terminal size is only the default base; the GUI chooses its own sizes (slice 7). |
| chrome.radius | pane 0 · card 8 · chip 4 · toast 8 · pill 999 | Rounded quads for cards, chips, pills, toasts only. |
| chrome.gap | 0 between panes; 8 sidebar margins | As today. |
| chrome.heights | top 38 · tabs 32 · pane header 22 · status 26 (logical px) | Chrome pixels are subtracted before `TerminalMetrics`; PTY sees complete cells only. |
| ring.attention | 2px inside the pane in the status color | Only for `blocked` and `failed`; off while the pane is focused. |
| dim.unfocused | pane background at alpha 0.15 over unfocused panes | Ghostty's `unfocused-split-opacity`. One quad per unfocused pane. |
| toast.policy | max 2 visible; skipped when the agent's pane is visible | Today 4, always shown. |
| motion | pulse 2 s / 6 steps · toast smoothstep · ring fade 300 ms | All from `sidebar_animation_frame`. |
| status glyphs | `⚠` `?` `◌` `✓` `✕` `·` | Colors per P2. Nerd Font theme may substitute. |
| theme.default | Osaka Jade (`dev/osaka-jade.lua` values) | Built-in; `yellow` distinct from `accent`. |

## The window

Top bar (38px): traffic lights with the native titlebar hidden (macOS),
numbered workspace pills with an attention dot, the selected workspace's
location (`▣ ~/sandbox/telar ⎇ main worktree`, mono) on the right, TLS badge.

Sidebar (284px default, resizable 220..480): header `agentes · N · M te
necesitan`; one ordered list of cards; footer = Lua slot (default
`metrics`).

Tab strip (32px): `1 agents`, `2 editor`, `3 perf ●`, `+`; active tab
connected to the workbench background; attention dot in the status color.

Panes: 1px `surface1` border, `accent` border when focused, inner 2px ring in
the status color when its agent is blocked or failed; header of 22px with
index, program name and a status chip (`permiso`, `trabajando 4m`); progress
as the existing 2px bottom stroke.

Status bar (26px): mode chip (`PREFIX`, `COPY`) and hints. Nothing else.

Toast (top right, 300px): title in the status color, message, `clic para ir
al pane · 4s`, close target. Max 2 visible.

Palette (centered overlay, 620px): `>` actions, `@` agents and panes, `?`
suggest. History keeps its modal.

New-context form (centered, 560px): Name; Working directory with a
completion list (directories only, `~` and `$VAR` expanded, branch and
active agents shown when the path is already a workspace); `tab` complete,
`↑↓` choose, `↵` create, `esc` cancel. A non-existent directory asks before
creating.

## The card

```
▣ telar                          hace 3m
fix proxy tests
¿Ejecuto zig build test?        ⚠  [✳]
```

- Row 1: project favicon if one exists in the workspace root
  (`favicon.ico`, `favicon.png`, `.telar/icon.png`), else a generic glyph;
  workspace name; age of the last status change, right-aligned. 11px
  `subtext0`.
- Row 2: `session_title` (placeholder until generated, manual or agent
  title). 13px SemiBold `text`.
- Row 3: last event (≤ 96 B, `overlay1`, ellipsis) left; status icon in its
  color (+ elapsed time for working) and the 16px provider mark right.
- Selected: `surface0` fill, inner 1px `surface1` ring, no side bar. The
  selection projects the focused pane; it is not a second focus.
- Degradation right to left: age → mark → last event.
- The favicon is resolved once per workspace in the client, off the
  interactive path, and enters the atlas like provider marks. It never
  crosses the wire as bytes.

## Snapshot additions (wire and replica)

`AgentSnapshotEntry` and `src/client/agents/Agent.zig` gain:

| Field | Type | Source |
| --- | --- | --- |
| `blocked_reason` | enum(u8) `none, permission, question, plan, other` | Runtime: hook report when present, else the last tool call seen by the proxy in the final assistant message (permission) or a screen heuristic (question). Presentation only; never authorizes an action. |
| `last_event` | ≤ 96 B, one control-free UTF-8 line | Runtime, from the observation path: pending question or permission text when blocked; last tool call (`» Edit src/…`) when working; result summary when done/ready. |
| `status_age_s` | u32 seconds since the last status change | Runtime clock at encode time. Drives the age label and the recency order. |

Bounds follow the existing pattern: fixed storage in the replica,
`agents.Snapshot.replace` still allocates nothing, revision rules unchanged.
`docs/sidebar.md` is updated: the card no longer shows the location row.

## Slices

Each slice keeps `zig build test`, `zig build test-gui`,
`zig build test-gui-window` and `zig build check-client-boundaries` green
and adds a capture under `docs/validation/`.

1. **Rounded quads and chrome face** (`feat/gui-vl-render`). `Quad` gains
   corner radius and border width/color; the ABI change is mirrored in
   `macos/window.m`, the Linux backend and both shaders (SDF in the fragment
   shader). `Canvas.fillRounded` and `Canvas.ring`. IBM Plex Sans embedded as
   a fourth face in `FontSet` with its own advances; `Canvas.text` accepts a
   face selector and measures proportional labels before clipping. Asset
   provenance recorded in `src/assets/README.md`.
   Done when a chrome label renders in the sans and a rounded card renders on
   macOS and in the Wayland VM, `stty size` still reports complete cells and
   `tools/gui_composition_latency.py` does not regress.
2. **Snapshot fields and the comparator** (`feat/gui-vl-snapshot`). The
   three fields above end to end: schema, golden, runtime encoding, client
   replica, `docs/sidebar.md`. The attention comparator in `telar-client`
   as one pure function with tests over the four groups and recency.
3. **New-context form, theme and defaults** (`feat/gui-vl-context`).
   `name_prompt` gains a second field for `create_workspace` (bound
   `max_cwd_bytes`) that fills `CreateWorkspace.launch.cwd`; a bounded,
   cancelable path-completion worker in `telar-client` (≤ 64 directories,
   4096 B per path); TUI and GUI render the two fields and the list. Osaka
   Jade as built-in and default theme. `gui.window.titlebar` default `false`
   on macOS. `bars.sidebar_footer` slot list with `metrics` default.
4. **Sidebar and card** (after 1 and 2). Rewrite `Sidebar.zig` and
   `AgentCard.zig`: header with counts, ordered list without headers, the
   three-row card with favicon, status icon and provider mark, degradation by
   width, favicon resolution off the interactive path.
5. **Tab strip, pane header, rings, top bar location** (after 1). `Regions`
   in logical pixels for bars and strip; `tabs.zig` in its own strip;
   `PaneDecorations` header, focus border, attention ring, unfocused dim;
   top bar location component; status bar reduced to mode and hints.
6. **Palette** (after 1). One overlay wrapping `picker.zig` and
   `suggestion.zig` with `>` `@` `?` prefixes; the `telar-client`
   controllers do not change; history keeps its modal.

7. **Chrome text sizes** (`feat/gui-vl-sizes`). The GUI is free to pick
   sizes; the terminal size is only the default base. `ChromeMetrics` gains
   three text sizes derived from the base: `title` (×1.0), `body` (×0.87),
   `small` (×0.73), all rounded to physical pixels, plus a Lua
   `gui.chrome.scale` factor (0.5..2, default 1) applied on top. `Label`
   takes a size role; `Canvas.text/textAt/measure` shape at that pixel
   height. Facts today: `TextRun.pixel_height` already reaches the atlas
   and `GlyphAtlas.place` re-selects a size per run, but `select` clears
   the whole shaping cache and re-selects every face, so alternating sizes
   within one frame thrashes. The atlas must hold several sizes at once:
   shaping-cache and glyph keys include the pixel height (glyph keys
   already do), faces keep one `FT_Size` per active height or set the size
   per run without invalidating caches, and the warm-repaint tests must
   still show zero shaping and zero allocation with three sizes in one
   frame. Card rows, the top bar, the tab strip, the pane header, the
   status band, the palette and the new-context form use the roles from
   the plan (context rows and footers `small`, titles `title` SemiBold,
   everything else `body`).
   Done when: a frame with the three sizes repaints warm with zero shaping
   and zero allocation, the card at base 15 shows 13px body and 11px
   context rows in a capture, and `gui.chrome.scale = 1.5` enlarges the
   chrome without changing the PTY size.
8. **Sprites: provider marks and favicons** (`feat/gui-vl-sprites`). The
   marks are images, shared with the TUI: `src/assets/provider-marks-768x256.rgba`
   and `telar-mark-64.rgba` are already embedded raw RGBA sprites built by
   `tools/build_provider_atlas.py`. Add an RGBA sprite page next to the
   alpha glyph atlas: one RGBA8 texture (Metal and Vulkan) bound beside the
   atlas, a quad attribute selecting the sampled texture (the shape vector
   from slice 1 reserves two zero components), premultiplied on upload,
   and `Canvas.spriteAt(bounds, sprite_id)`. Provider marks come from the
   embedded sheet at startup; favicons are decoded from `favicon.png` or
   `.telar/icon.png` in the workspace root (PNG only, 8-bit, non-interlaced,
   through `std.compress.flate`; ICO is not supported), resized to the
   sprite cell with a box filter, by a bounded worker off the interactive
   path (one job in flight, 256 KiB file cap, 4096 px² cap), cached per
   workspace, and published to the card's `project_icon` hook as a sprite
   index. The sheet is bounded: 64 favicon cells plus the provider marks;
   a full sheet keeps the generic glyph. No image bytes cross the wire.
   Done when: the card shows the Claude, Codex and Pi marks from the sheet
   and a workspace with a `favicon.png` shows it after at most one frame
   following the worker's completion, on Metal and Vulkan, with the same
   warm-repaint guarantees.

## Contract

- Zero allocation on the interactive path. New labels have fixed fields;
  the runtime truncates, the client copies.
- `HitMap.capacity` grows by constant: 4 toast closes, 16 palette rows. No
  section headers, so no new sidebar hits.
- One quad per surface: a rounded rectangle is a quad with radius and border
  attributes resolved by the fragment shader.
- The PTY sees complete cells only; chrome pixels are subtracted before
  `TerminalMetrics`.
- Animation by counter: pulse, ring and toast read
  `sidebar_animation_frame`; no element owns a timer.
- No authority: `blocked_reason` changes the chip text; it never enables a
  key that sends `y` to the agent without a hook behind it
  (`docs/engineering-invariants.md`).
- Attention aggregates upward: a blocked pane puts a dot on its tab, on its
  workspace pill and a count in the sidebar header; the comparator picks the
  color when several apply.

## Not built

- A widget framework (out of scope per `docs/plans/native-client-split.md`).
- Tabs per pane (cmux), terminal as a drawer (T3), embedded browser,
  kanban, containers per task.
- Rasterized text in the chrome: all text goes through the glyph atlas; no
  action depends on a pixel.

## Risks

- Metal / Vulkan parity of the rounded-quad SDF: image test comparing the
  same frame on both backends, as the box-drawing validation does.
- Proportional face: one more embedded font (≈ 200–400 KB) and two advance
  metrics in one atlas; label widths are measured, not `n` cells.
- Quad budget: four more quads per card, 256 worst case, reserved at geometry
  time in `frame_budget.zig`.
- Chrome in pixels changes the grid and therefore the PTY size; same path as
  padding today (`ResizeHostHandler`); a font reload must not trigger two
  resizes.
- Wayland without `xdg-decoration` keeps the native titlebar: two looks,
  documented.
- Blocked reason without a hook comes from a heuristic; it is display only.
