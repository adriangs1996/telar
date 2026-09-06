# Agent mode mockups

Cell-exact references for the widgets described in
[`../../agent-mode.md`](../../agent-mode.md). Each mockup exists twice:

- `NN-name.txt` is the plain screen, one line per row, every row padded to the
  mockup's width. Column positions are the specification: separators,
  section headers, chips and the action row must land on the same columns.
- `NN-name.roles.txt` is the same screen with every styled run wrapped as
  `«role:text»`. Unwrapped text uses the default foreground.

Files whose name starts with `considered-` document alternatives the review
rejected. They are kept so nobody proposes them again without reading why.

## Widths

| File | Width | Rows | What it fixes |
| --- | --- | --- | --- |
| `01-multiplexer-mode-today` | 100 | 13 | Today's mode as a baseline, from `docs/sidebar.md` |
| `02-agent-mode-wide` | 100 | 13 | Agent mode at 100 columns: 17 / 34 / 46 columns for projects, inbox, view, two 1-column separators |
| `03-agent-mode-narrow-list` | 46 | 12 | Under 90 columns, list form: projects strip on top |
| `04-agent-mode-narrow-detail` | 46 | 12 | Under 90 columns, detail form |
| `05-considered-cockpit-layout-B` | 100 | 16 | Rejected layout B |
| `06-conversation-view` | 100 | 17 | Conversation view: user anchors, tool lines, edit diff, permission line, compaction separator |
| `07-composer-K4-design` | 88 | 8 | The composer at 120 columns or more: 60-column editor, 25-column settings column |
| `08-composer-K3-narrow-form` | 88 | 7 | The composer under 120 columns: bare editor, command popup, status line |
| `09-considered-composer-K1` | 88 | 8 | Rejected composer K1 |
| `10-considered-composer-K2` | 88 | 8 | Rejected composer K2 |
| `11-composer-state-working` | 88 | 8 | K4 while the agent works: queue and stop |
| `12-composer-state-blocked` | 88 | 8 | K4 with a hook-reported permission: editor replaced, y / a / n / i |
| `13-composer-state-live-change-pending` | 88 | 8 | K4 after a live model change, before the transcript confirms |
| `14-composer-state-new-thread` | 88 | 11 | K4 for a new thread: project, worktree, base, branch, provider, options, create |

The wide mockups are drawn at 100 and 88 columns for the page; the widgets
scale their middle columns with the terminal and keep the fixed ones (the
projects column, the settings column) at the widths above.

## Role legend

Roles map to `theme.Palette` fields in `src/frontend/ui/theme.zig`.

| Role | Foreground | Background | Weight |
| --- | --- | --- | --- |
| `wh` | `text` | inherit | bold |
| `ac` | `accent` | inherit | regular (bold for section titles) |
| `gr` | `green` | inherit | regular |
| `rd` | `red` | inherit | regular |
| `tl` | `teal` | inherit | regular |
| `mv` | `mauve` | inherit | regular |
| `sb` | `subtext0` | inherit | regular |
| `dm` | `overlay0` | inherit | regular |
| `hdr` | `overlay1` | inherit | bold |
| `sel` | `text` | `surface1` | regular |
| `bar` | `subtext0` | `panel_bg` | regular |

Default foreground for unwrapped text is `text` at regular weight over the
panel background (`panel_bg`), the same base the sidebar uses.

## Glyphs

Every glyph is one cell wide and present in JetBrains Mono and in the
Unicode icon theme telar already ships: `●` blocked or selected project,
`◐` working, `✓` done, `·` ready, `▸` and `▾` expander, `▌` user prompt
anchor and caret, `❯` agent prompt, `»` tool call, `!` permission, `*`
provider mark placeholder (the KGP atlas replaces it), box drawing
`┌ ┐ └ ┘ ├ ┤ ┬ ┴ │ ─`, dotted `┈` for the drawer separator, `▮ ▯` for the
context bar. The Nerd Font theme substitutes its own glyphs for `●`, `◐`,
`✓`, `·` and the provider mark exactly as the sidebar does today.

## Regenerating

The mockups were generated from a small Python script kept with the review
session; the text files are the source of truth now. Edit them directly and
keep every row padded to the file's width.
