# Native terminal appearance

The external triggers are `telar gui --config PATH [--profile NAME]`, a saved
configuration or imported module, a native display scale or focus change, a
child's VT cursor request, and the next cursor
blink deadline. [Configuration](../configuration.md#graphical-application)
defines the Lua API and current scope.

## Configuration and fonts

`client/config/Generation` validates root/profile themes with `ThemeParser` and
native preferences with `GuiConfigParser`. `appearance/Theme` owns chrome roles
and a `TerminalTheme` with explicit colors. `GuiConfig` owns bounded font and
cursor behavior preferences. No native handles or Lua string pointers enter
shared client state. Invalid numbers, colors, fields and incomplete palettes reject the generation.
`cli/ClientLaunch.frontendOptions` transfers the selected snapshot to
`gui/Application.init`.

`render/TerminalRenderer.configured` stages the native resources before the
window starts. `text/FontSource` resolves an installed family through the small
`native/font.h` port: CoreText supplies a file and PostScript face name on macOS;
Fontconfig supplies a file and collection index on Linux. The renderer owns the
file bytes, bounded to 64 MiB. The bundled JetBrains Mono needs no lookup or file
allocation. Explicit lookup failures abort this GUI startup.

FreeType borrows those bytes until `GlyphAtlas.deinit`; the source is freed
after the atlas. Collection lookup is bounded to 256 faces on macOS. HarfBuzz
shaping, glyph caching, fallback glyphs and synthesized bold/italic retain their
existing ownership. No font lookup or disk read occurs while preparing cells.

`TerminalRenderer.measure` derives the physical font size from the configured
base size and display scale. Natural advance plus letter spacing determines
cell width; natural line height times `line_height` determines cell height.
Metrics round to physical pixels and are validated before use. The existing
`TerminalMetrics` computes complete grid cells. Initial client pixel dimensions
are exactly `columns * cell_width` and `rows * cell_height`; resize follows
`ResizeHostHandler`. The runtime receives these dimensions through `pane_resize`
and propagates them to the PTY.

## Hot reload

`GuiClient.start` schedules the existing `config_reloads` controller through
`host_ports.configWatcher`. `ConfigurationReload` owns one worker and one
pending result. Its worker calls the shared `config_reload.wait`: the same
one-second fingerprint watch, selected profile, local modules, plugin registry
and trust-store loading as the TUI. It also prepares a replacement
`TerminalRenderer` when `GuiFont` changes, including font bytes, metrics, atlas
fallbacks and grid capacity. Theme/cursor-only changes retain the active atlas.

The worker receives copied appearance/viewport values and borrowed current Lua
owners for fingerprinting. It never reads a live renderer or mutates the model.
Completion wakes the native pipe. `RuntimeDriver.drain` joins completed work;
unchanged fingerprints rearm without requesting a draw. A changed result waits
for `Application.prepare`, after the previous presentation token has ended.
Input, socket reads and receipt ACKs continue while a candidate waits.

`ConfigurationReload.apply` checks the current viewport before adoption. A
window resize or display-scale change restages the candidate off-thread for
the new viewport. Native preparation failure releases the candidate Lua owners
through the existing orphan cleanup and becomes a shared rejected reload. The
old generation, font and colors remain active. Shared validation rejection
also discards the staged renderer. Diagnostics use the model's existing
diagnostic state and the `gui_config` stderr log scope; the GUI does not yet
paint the TUI diagnostic banner.

Successful adoption uses `config_reloads.handle` to commit the shared model and
swap its Lua owners. The GUI then installs the prepared renderer, applies the
typed colors/cursor settings, resets `CursorClock` and publishes metrics and
terminal defaults through `ResizeHostHandler`. A replacement renderer inherits
the previous atlas version so its next preparation forces a GPU texture upload.
Fallible shared effects after the model commit retain that new generation; the
native resources follow it even if a downstream error ends the client.

`Snapshot.resolveTheme` gives both adapters the same appearance/CLI precedence.
The GUI captures the resulting terminal colors before adoption can release a
rejected candidate. A locked CLI theme survives a Lua reload while font changes
still apply. The renderer holds a resolved copy of `Theme.terminal`; there is
no separate GUI theme selector. A named preset change updates the chrome theme
and native palette together, without rebuilding font resources.

The replaced renderer is retired only after its native consumers finish, then
freed by the next worker before loading another candidate. There is at most one
active renderer and one staged or retired renderer. Rearm records a request;
the driver launches it after adoption has finished, so it captures the new
font settings. Window close cancels and joins this worker before destroying
the client generations or closing the wake pipe. A pending unadopted generation
remains in the shared orphan slots until client teardown. This component uses
the existing host port and can move to the step 9 inbox/outbox driver without
moving native font policy into `src/client`.

## Colors

The root `theme` selects chrome roles and terminal defaults together. Optional
`theme.colors` and `theme.terminal` override those groups independently.
`TerminalRenderer` resolves indexed/default cells with the terminal palette and
truecolor cells directly. Changed foreground, background or ANSI entries
invalidate retained cell geometry. Cursor colors reuse that ink. Positions and
text remain owned by the shared client model.

`Application` supplies `TerminalColors` through the existing
`configure_terminal_colors` bootstrap. The runtime's existing geometry authority
chooses which attached host supplies VT defaults. `Pane.setTerminalColors`
defers updates during ingestion; `applyTerminalColors` changes the defaults
without overwriting child OSC overrides. `DynamicPalette.changeDefault` retains
changed entries until OSC 104 resets them. OSC 4/10/11 queries are answered by
the VT. Blitting preserves default/indexed semantics except when a child has
overridden those values, in which case it projects the effective RGB value.

## Cursor and native wakeups

The runtime VT interprets DECSCUSR, DECTCEM, DEC mode 12 and resets.
`Pane.render` projects visibility, viewport position, default/explicit shape
and blinking into `Cursor`. `pane_frame` carries the shape and blinking as
validated wire bytes. The shared value stores appearance in one packed byte,
preserving the six-byte cursor footprint in bounded client models. The schema
version and golden-corpus fingerprint change with this protocol; runtime and
client must use matching builds.

`GuiClient.cursorTarget` returns the visible focused terminal's ID, attachment
generation and cursor. `CursorClock` retains only this owned value, GUI cursor
defaults, focus and the beginning of the current phase. It resets when the
target changes or input/focus arrives. Its next deadline is computed directly;
late callbacks fold missed phases rather than replaying animations. Hidden,
steady and unfocused cursors have no deadline. There is no timer per pane.

`Application.pump` requests a draw only when the model, cursor phase or focus
differs from the prepared scene. The optional `Callbacks.wakeup_after` port
returns relative milliseconds, with zero meaning no deadline. macOS uses one
reusable dispatch timer on the main queue, paused while the window is occluded.
Linux folds the deadline into the existing native `poll` timeout. Neither host
implements cursor policy. Their display clocks still decide when a pending
frame can be submitted.

`CursorPaint` appends quads after retained cell ink. Filled blocks redraw the
covered glyph with the configured cursor text color, reusing cached texture
coordinates. Bar, underline and hollow cursors need solid rectangles only.
A cursor in a wide cell's continuation starts at the leading cell and covers
its clipped width. An unfocused window shows a steady hollow cursor. These
changes do not reshape text, replace atlas resources or modify cell meshes.

ACKs continue to mean successful application of owned state; blinking does not
send new ACKs for already applied frames. GPU completion still releases the
captured presentation token. Native consumers own sealed frames and never
borrow a mutable client model. Step 9 can replace `RuntimeDriver` while retaining
the typed config, font resources, cursor clock and rendering contracts.

## Verification and lifecycle

- `zig build test-client`: defaults, profile inheritance, owned font names,
  strict schema validation and invalid unselected profiles.
- `zig build test-schema`: cursor/palette round trips, malformed flags, unknown
  cursor shapes, truncated messages, golden bytes and handshake fingerprint.
- `zig build test`: fragmented VT style and palette queries, overrides and
  resets, plus existing client/runtime/transport regressions.
- `zig build test-gui`: installed font resolution, missing family failure,
  scaled metrics, all cursor shapes, wide-cell ink, palette rendering and
  allocation failure after warmup. Twenty cursor phases reuse the atlas and
  retained cell meshes without adapter allocations. Reload tests exercise real
  watched files, atomic module saves and profiles; native/Lua rejection and
  recovery; sealed frame lifetime with continuing input/ACKs; atlas reuse and
  versioning; named theme changes and CLI locks; cursor-only color changes
  without repainting cells; viewport restaging; unchanged idle watches and
  cancellation.
- `zig build test-gui-window`: a real macOS window wakes once for a deadline,
  parks afterwards, coalesces draw requests and closes with a submission alive.

Native integration also accepts a Lua configuration. On macOS,
`python3 tools/gui_lifecycle.py zig-out/bin/telar /tmp/telar-gui-check --config examples/gui.lua --capture`
exercises typing, PTY resize and shell survival and saves a window screenshot.
On Linux,
`python3 tools/vm/gui-terminal-test.py /tmp/telar-wayland-check --config examples/gui.lua`
adds clipboard paste, reattachment and Vulkan validation in the isolated VM
runtime. The VM uses software Vulkan; this is correctness evidence, not a
hardware performance measurement.

Use `--reload` instead of `--config` in either native integration command to
generate an isolated watched configuration. The test changes the font and PTY
grid, rejects an unavailable font without changing the active appearance, then
recovers and checks shell survival. The macOS wrapper also inspects native
frame colors, atlas versions and cursor deadlines. Linux captures each stage
and checks Vulkan validation and reattachment. Both replace config files
atomically and leave the user's configuration untouched.

Verified on 2026-09-13: `zig build test` passed 3,278 cases on macOS with two
platform skips and all 3,280 cases on Fedora aarch64. `zig build test-gui`
passed all 37 cases on both hosts, including native resource ownership after
a shared post-commit delivery failure. Client boundaries and codestyle passed.

The macOS hot-reload test changed PTY size from 54x192 to 35x133 with Menlo 22,
then to 48x173 with the bundled face at 17. The Wayland test changed 37x70 to
24x48 with DejaVu Sans Mono 22, then to 34x63 at 17. Sizes are rows x columns.
Both switched between the Catppuccin and Tokyo Night presets, rejected an
unavailable font while retaining the previous theme and grid, accepted a
corrected file and kept the shell alive. Linux also resized the window to a
27x90 grid, pasted UTF-8 and reattached to the same shell with no Vulkan
validation errors. The macOS frame wrapper verified new background colors,
increasing atlas versions and enabled/disabled cursor deadlines.

Font/config preparation is bounded startup or reload work, separate from the
interactive path. One clock, one native timer and bounded cursor quads serve
the visible cursor. Window close cancels the timer and GPU consumers before destroying
rendering resources and the connection. Runtime panes survive that close.
Font zoom remains a future trigger; callers replacing the staged renderer must
first finish its native consumers.
