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
cursor behavior preferences, plus `GuiWindow` and its logical `GuiPadding`.
No native handles or Lua string pointers enter
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
after the atlas. Collection lookup is bounded to 256 faces on macOS.
`text/FontSet` owns at most five embedded or configured `FontFace` instances:
the configured font, embedded JetBrains Mono when it differs, embedded Symbols
Nerd Font Mono, and embedded IBM Plex Sans Regular and SemiBold for native
chrome labels, plus a `FallbackPool` of at most eight installed faces
discovered at runtime. The configured font wins whenever it covers a whole
grapheme. Missing graphemes try the embedded text font, the symbol font and
then the discovered faces in discovery order; unknown characters retain the
configured font's replacement glyph.

Discovery is automatic and monochrome. When a run's shaping result is not
cached, `GlyphAtlas.discoverFallbacks` walks its graphemes once and, for each
one no resident face covers, asks the `native/font.h` port which installed
face covers it: `CTFontCreateForString` over Menlo and then every descriptor
whose character set covers the text on macOS, an `FcCharSet` pattern through
`FcFontSort` on Linux, monospace candidates first. The port skips color faces
(sbix, CBDT, COLR; Apple Color Emoji), bitmap-only faces, Apple's LastResort
and files over 64 MiB, and `FontFace.monochrome` rejects the same after
loading. A hit reads the file once (the same 64 MiB bound and `FT_Size`
handling as the configured face) into one pool slot keyed by file, index and
PostScript name, so one installed file serves every grapheme it covers. A
miss, an unusable file or a full pool is remembered in `GraphemeMisses`, a
256-entry direct-mapped negative cache, so each grapheme costs one native
lookup. The pool never evicts: a shaped run cached against slot N means the
same face until a font reload rebuilds the set, its atlas and both caches.

This is cold-path work only: a warm repaint hits the shaping cache before
discovery runs, and warm tests prove no lookup, shaping, rasterization or
allocation after the first sighting. The cost of a first sighting is one
CoreText or Fontconfig query (tens of milliseconds the first time CoreText
enumerates descriptors) plus one file read of at most 64 MiB, on the same
path that already rasterizes the new glyph. Discovered ink is fitted into
the cell like the embedded fallbacks; the configured font keeps cell
dimensions and baseline. Color emoji remain a gap: the alpha page cannot
hold them, so a grapheme only color faces cover keeps the replacement glyph.
An atlas opened without an `Io` (unit tests) never discovers.

Terminal cells never select the sans faces. A chrome `Label` with
`face = .sans` shapes as one HarfBuzz run in Plex Sans with its own
proportional advances and bearings; `bold` selects the SemiBold file rather
than synthetic emboldening. Graphemes Plex lacks, such as Nerd icons, follow
the terminal chain and are fitted to one cell of the label's size. `Canvas.measure`
returns a label's pixel width so callers clip or right-align whole tokens;
`Canvas.text` clips a sans label at the area's pixel edge.

A sans label also carries a size role. `ChromeMetrics` derives three pixel
heights from the scaled terminal size: `title` (x1.0), `body` (x0.87) and
`small` (x0.73), times `gui.chrome.scale` (`0.5..2`), rounded to device
pixels and never below 6. The bands keep their heights; `body` is capped at
the largest em whose Plex line box (1.3 em) fits the pane header, so at
`font.size = 15` it stops at 16 px while `title` and `small` keep growing.
`Label.size` defaults to `terminal`; `Canvas.textAt` centres the role's own
line box (`GlyphAtlas.lineBox`) in the row, and terminal-sized or monospace
labels keep the cell box so they share a baseline with cells. Cards use
`small` context and event rows and a `title` SemiBold row; headers, pills,
tabs, pane headers, palette rows and the new-context form use `body`.

Every `FontFace` keeps one `FT_Size` per pixel height it has painted (at
most eight) and activates it per run, so terminal cells and the three chrome
sizes shape and rasterize side by side without clearing anything.
Shaping-cache entries are keyed by the requested face and the pixel height
as well as the text, so equal words in two families or at two sizes never
share glyphs or advances. A chrome scale change re-measures the chrome on
the next frame and reuses the atlas; the PTY size never changes with it.

The GUI embeds the complete Nerd Symbols font, including supplementary-plane
icons used by terminal applications. The TUI keeps its small chrome-only subset.
[Asset provenance](../../src/assets/README.md) records the pinned version,
checksum and licenses. No font installation or extra Lua setting is required.

`FontRuns` selects faces at grapheme boundaries, keeping combining marks with
their base. Shaping-cache entries retain the face identity, and atlas keys combine
that identity with glyph index, size and style. Equal glyph indices in two fonts,
including two discovered pool slots, cannot alias. All faces share the existing alpha page. Fallback quads fit the
primary grid; the configured font continues to determine cell dimensions and
baseline. Font reload replaces the set together with its atlas and caches.

Retained cell meshes preserve the configured font's complete bitmap and bearings.
Pane composition clips ink only at the pane boundary, allowing italic overhang
between cells and rows without drawing into another pane. Backgrounds precede
ink. Box drawing and Braille use the full configured grid through the shared
[procedural glyph path](gui-procedural-glyphs.md).

On macOS, `gui.font.thicken` opts into `text/MacRasterizer` through the small
`native/glyph_rasterizer.h` port. `macos/glyph_rasterizer.m` opens the same font
bytes and PostScript face selected by FreeType; it does not register fonts or
substitute an installed family. Each face's alpha-only CoreGraphics bitmap
context borrows the same atlas page. Sized CoreText faces use their own glyph
IDs and the primary baseline; the primary FreeType metrics remain unchanged.
Contexts and faces are destroyed before their borrowed page and font bytes.

This uses CoreGraphics font smoothing and its grayscale optical weight,
following [Ghostty's font-thicken controls](https://ghostty.org/docs/config/reference#font-thicken).
`thicken_strength` is an integer `0..255`; zero is the lightest enabled smoothing,
and only `thicken = false` disables it. Synthetic bold and italic remain
independent. Glyph bounds include smoothing and stroke overhang before packing.
Drawing clips and clears only the reserved rectangle, preserving neighbors and
the solid-quad texel. Cache hits bypass native rasterization; cold misses share
the existing alpha page, without an additional bitmap per glyph or a GPU pass.
Linux continues using FreeType and ignores both optical weight settings.

`TerminalRenderer.measure` derives the physical font size from the configured
base size and display scale. Natural advance plus letter spacing determines
cell width; natural line height times `line_height` determines cell height.
Metrics round to physical pixels and are validated before use. The existing
`TerminalMetrics` computes complete grid cells. Initial client pixel dimensions
are exactly `columns * cell_width` and `rows * cell_height`; resize follows
`ResizeHostHandler`. The runtime receives these dimensions through `pane_resize`
and propagates them to the PTY.

## Window effects and padding

`gui.window` owns background opacity, a blur radius, native titlebar visibility
and symmetric horizontal/vertical padding. Opacity is finite in `0..1`; blur
is an integer in `0..255`, with zero disabling it. Legacy booleans map to
`true = 20` and `false = 0`. The titlebar defaults to visible, and each inset
is finite in `0..256` logical pixels. These are disposable host preferences, never
runtime authority or a second theme. They inherit through profiles and use
the same atomic configuration reload as fonts and colors.

`TerminalRenderer.measure` scales and rounds the insets, keeps space for one
complete cell when the window shrinks, then measures the remaining viewport.
It retains the physical origin used by both cell meshes and cursor quads.
Padding changes follow `ResizeHostHandler`; neither initial attach nor resize
counts border pixels as PTY pixels. Retained mesh keys already include the
resolved rectangle, so moving the origin invalidates exactly that geometry.
Opacity and blur changes do not invalidate cell meshes or the glyph atlas.

`render/Quad` is an 80-byte `extern struct` of five `vec4` rows: rectangle,
texture coordinates, straight RGBA fill, shape (corner radius, border width,
texture selector and one zero reserved float) and straight RGBA border color.
Both fragment shaders resolve radius and border by signed distance in device
pixels with one pixel of anti-aliasing; a quad with zero radius and zero border
takes the previous textured path unchanged. `Canvas.fillRounded` and
`Canvas.ring` emit one such quad each; `Canvas.fill`, `Canvas.border` and
glyphs keep zero shape.

The texture selector chooses the sampled page: zero reads the alpha atlas as
coverage, one reads `image/SpritePage`, a 512² premultiplied RGBA8 page bound
beside the atlas on both backends (`MTLPixelFormatRGBA8Unorm`,
`VK_FORMAT_R8G8B8A8_UNORM`, linear sampling). The shaders divide the texel
back to straight alpha for the blend state and multiply the quad's tint. The
page holds equal square cells of `SpritePage.cellFor(scale)` texels, 16
logical pixels at the display scale, clamped to 8..48: the three provider
marks box-filtered from the embedded sheet at construction, then at most 64
workspace favicons. `TerminalRenderer.measure` builds it with the atlas for
the same scale; `seal` advances `sprites_version` only when a cell was
written, so the backend uploads the page once per landed favicon and never on
a warm frame. `native.Frame` carries the page pointer, side and version
beside the atlas; a frame without a page leaves the atlas bound in the sprite
slot and no quad selects it. `Canvas.spriteAt` draws one cell into a
device-pixel rectangle, snapped to whole pixels, as one quad with zero shape.

Workspace favicons never cross the wire. `chrome/Favicons` keeps one entry per
workspace of the list; each preparation places the one landed image into the
page and asks `controllers/workspaces/favicons` to look up the next wanted
workspace when the client's `favicon_runner` is bound (the TUI leaves it
unset). The GUI job runs on an inbox task: the shared `favicon_lookup` reads
`favicon.png` then `.telar/icon.png` under the workspace root (regular files,
256 KiB at most), `image/png` decodes 8-bit non-interlaced RGB, RGBA or
palette files under `PngLimits` (4096 px a side, 1 Mi pixels) into a fixed
scanline buffer, and `image/box_filter` area-averages the result into one
cell. One lookup is in flight at a time; a completion for another execution
is released unread, a missing file is silent and an unusable one logs once
under the `favicons` scope. A full sheet or a failed lookup keeps the generic
glyph. A page rebuilt for another scale forgets its placements, so the
lookups run again at the new cell size.

`native.Frame` carries straight RGBA background, a numeric blur radius and
titlebar visibility. These values cross only the in-process native ABI; they
do not change the runtime protocol. Both GPU
backends clear their target with premultiplied RGB and blend straight-alpha
quads into that target. A different explicit cell background and ordinary ink
remain opaque; cells matching the terminal background reuse the clear color.
No extra Telar render pass or frame queue is introduced.

On macOS, `TelarWindowBackground` owns background effects behind `TelarView`.
`TelarBackgroundBlur` isolates optional lookup of the private WindowServer
functions used by Ghostty, including `CGSSetWindowBackgroundBlurRadius`.
It sets the radius only when the effective setting changes. Window alpha
stays at one. If the functions are unavailable or reject the radius, one
diagnostic accompanies a public `NSVisualEffectView` fallback with
system-managed intensity. Zero blur and an opaque background disable the
effect. Closing the window releases it with the content hierarchy after the
existing renderer shutdown.

`TelarWindow` owns titlebar visibility and defers style changes during native
fullscreen. A hidden titlebar keeps the window's titled style and adds
`FullSizeContentView`, hiding the title and standard buttons. It preserves the
outer window frame and keyboard focus. When that change alters the viewport,
`TelarView` discards the prepared presentation token with `delivered = 0` and
prepares a frame using the new size. Layout notifications cannot reenter that
preparation. The ordinary `ResizeHostHandler` updates the terminal grid; no
old-size frame is submitted to Metal.

On Wayland, `background_effect` owns at most one effect manager and one effect
surface on the window thread. It negotiates
[ext-background-effect-v1](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/staging/ext-background-effect/ext-background-effect-v1.xml),
observes capability changes and global removal, and updates blur/opaque
regions only on changed settings, capabilities or viewport. Surface state is
committed with Vulkan's next presentation. Temporary region allocation occurs
on those transitions, not on steady cell frames. Teardown joins the GPU worker
before destroying effect objects and their borrowed surface.

The Vulkan swapchain prefers premultiplied alpha, then Wayland's inherited
premultiplied convention. It keeps that mode when opacity changes, without
rebuilding the swapchain. An opaque fallback preserves the original background
color and logs once if transparency was requested. Missing compositor blur
support logs once and retains ordinary transparency. The platform controls the
blur algorithm; positive radii map to the same enabled request on Wayland.

`linux/decoration` negotiates `xdg-decoration` before the first surface commit
and waits for its initial configure before permitting a buffer attachment.
Visible titlebars request server-side decorations; hidden titlebars request
client-side decoration with no Telar titlebar. The compositor may override that
preference. Reload updates an existing object only when the preference changes,
and fullscreen preserves the requested normal-window mode. Without the protocol
Telar does not draw a titlebar. Teardown releases decoration objects before the
toplevel; a manager advertised after mapping cannot create a late decoration.

## Hot reload

`GuiClient.start` schedules the existing `config_reloads` controller through
`host_ports.configWatcher`. `ConfigurationReload` owns one worker and one
pending result. Its worker calls the shared `config_reload.wait`: the same
one-second fingerprint watch, selected profile, local modules, plugin registry
and trust-store loading as the TUI. It also prepares a replacement
`TerminalRenderer` when effective font settings change, including font bytes, metrics, atlas
fallbacks and grid capacity. Theme, cursor and window-only changes retain the active atlas.
`text/font_rendering.same` excludes disabled strength and macOS-only settings
on other platforms, avoiding an unnecessary atlas replacement. On macOS an
optical weight change stages a new native context and page on that worker;
it follows the same consumer lifetime as any other font replacement and does
not alter the terminal geometry.

The worker receives copied appearance/viewport values and borrowed current Lua
owners for fingerprinting. It never reads a live renderer or mutates the model.
Completion publishes into a reserved inbox slot. `NativeLoop.drain` delegates
to `ConfigurationReload.accept`, which joins only that finished worker.
Unchanged fingerprints rearm without requesting a draw. A changed result waits
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
the existing host port and the shared inbox. Native font policy stays in
`src/gui`.

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

`CursorPaint` paints filled blocks after cell backgrounds and before retained
ink. Composition applies the configured cursor text color to the owning cell's
complete glyph, including overhang, without drawing its ink twice. Adjacent
italic ink remains visible. Bar, underline and hollow cursors append solid
rectangles above the ink.
A cursor in a wide cell's continuation starts at the leading cell and covers
its clipped width. An unfocused window shows a steady hollow cursor. These
changes do not reshape text, replace atlas resources or modify cell meshes.

ACKs continue to mean successful application of owned state; blinking does not
send new ACKs for already applied frames. GPU completion still releases the
captured presentation token. Native consumers own sealed frames and never
borrow a mutable client model. The inbox/outbox driver retains the typed
config, font resources, cursor clock and rendering contracts.

## Verification and lifecycle

- `zig build test-gui` (`tests/font_fallback.zig`): U+23F5 resolves to a
  discovered monochrome face fitted to the cell, a miss is looked up once,
  eight pool slots refuse a ninth face without evicting, one file serves
  every grapheme it covers, and the warm terminal and chrome tests repaint
  a discovered grapheme without lookups or allocation
  ([validation](../validation/gui-font-fallback/README.md)).
- `zig build test-client`: defaults, profile inheritance, owned font names,
  strict schema validation and invalid unselected profiles, including window
  effects and finite inset limits.
- `zig build test-schema`: cursor/palette round trips, malformed flags, unknown
  cursor shapes, truncated messages, golden bytes and handshake fingerprint.
- `zig build test`: fragmented VT style and palette queries, overrides and
  resets, plus existing client/runtime/transport regressions.
- `zig build test-gui`: the sprite page's bounds and premultiplication,
  sprite quads carrying the texture selector, the card drawing the three
  sheet marks and the chip for a custom provider, warm repaints with sprites
  that shape, rasterize and allocate nothing, the PNG decoder on synthetic
  files with every filter type and its rejections, the favicon registry,
  worker and one favicon reaching the card a frame after its completion;
  installed font resolution, missing family failure,
  scaled metrics, all cursor shapes, wide-cell ink, palette rendering and
  allocation failure after warmup. Twenty cursor phases reuse the atlas and
  retained cell meshes without adapter allocations. Reload tests exercise real
  watched files, atomic module saves and profiles; native/Lua rejection and
  recovery; sealed frame lifetime with continuing input/ACKs; atlas reuse and
  versioning; named theme changes and CLI locks; cursor-only color changes
  without repainting cells; viewport restaging; unchanged idle watches and
  cancellation. Optical weight tests compare native alpha coverage, clip all
  four glyph styles against sentinel pixels, preserve Unicode advances and
  cell metrics, and exercise the warmed glyph cache with a failing allocator.
  Weight-only reloads preserve PTY geometry; inactive settings preserve the atlas.
- `zig build test-gui-window`: a real macOS window wakes once for a deadline,
  parks afterwards, coalesces draw requests, toggles transparent/blurred/opaque
  state, changes numeric blur and titlebar visibility, enters/exits fullscreen
  with a pending preference, and closes with a submission alive. Titlebar
  changes preserve focus and retire frames prepared with the previous viewport.
  The Linux test checks swapchain
  alpha mode and premultiplied clear colors across Vulkan retries and effect
  toggles, including a compositor without blur support.
- `zig build test-gui-window-options` on Linux: decoration negotiation and
  configure ordering, compositor overrides, global removal and destruction,
  plus idempotent blur and decoration requests across repeated frames.

[Window option validation](../validation/gui-window-options/README.md) records
native reload results and the compositor limitations observed on 2026-09-13.

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
frame colors, atlas versions and cursor deadlines. It also enables smoothing
at strength zero, raises it to 255 and disables it again, requiring a new atlas
at each change and identical `stty size` throughout. Linux captures each stage
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

Window preferences were verified on 2026-09-13 with all 41 GUI and 860 client
tests on both hosts, both native window tests, and the macOS general suite
with 3,289 passing tests and two platform skips. Live window-only reloads
reused the atlas and changed rows x columns from 96x190 to 94x186 and back on
macOS, and 34x63 to 33x60 and back on Linux. Both shells survived. Sway in the
VM did not advertise blur; its transparency fallback and Vulkan validation
passed. Actual compositor blur appearance on Linux remains unverified.

Optical weight was verified on 2026-09-13 with 45 GUI and 860 client tests on
macOS. Fedora passed 44 GUI and 860 client tests, skipping only the direct
CoreGraphics coverage test. Client boundaries and codestyle passed. The native
macOS reload test kept a 96x190 PTY across strength 0, strength 255 and disabled
smoothing, accepted input and kept the same shell alive. The development
configuration also passed a native startup, input, resize and screenshot check
with DejaVu Sans Mono and thickening enabled.
