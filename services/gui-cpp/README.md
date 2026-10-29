# C++ Qt Quick GUI

An opt-in C++ client for the existing Telar runtime. Qt Quick owns the window,
input delivery and scene graph; QML owns the application chrome. The Zig GUI
remains the default. This port does **not** yet meet the requested functional,
visual or performance parity gates. [PARITY.md](PARITY.md) records the remaining work.

The latest [machine chrome checkpoint](measurements/machine-chrome.md) adds the
sidebar switcher and top-bar segment, with bounded folding, profile ink and
cross-machine attention. Scoped native shade Retina controls match the original
exactly; the activity displacement is corrected, with 15 card pixels still
different. Native interaction, original-source geometry/colors and selected
regressions pass. Native exit leaks and complete visual/performance acceptance
remain open.

Native startup selects Metal on macOS and Vulkan on Linux, matching the original
GUI's backends. Explicit Qt backend environment settings take precedence.
The tab atlas still exposes OpenGL edge differences; that override has no
tab-pixel parity acceptance.

## Boundaries

| Directory | Responsibility | Dependencies |
| --- | --- | --- |
| `application` | Runtime session, workspace/tab projection, layouts, attachment lifecycle | Protocol and allocator types |
| `terminal` | Owned cells, frame validation, damage revisions, text metadata | Protocol and allocator types |
| `terminal/font_grid.hpp` | Physical cell geometry and baseline arithmetic | Core preferences and C++ standard library |
| `fonts` | Borrowed font faces, variation coordinates, shaping, glyph masks and physical metrics | Pinned FreeType/HarfBuzz and native match records; no Qt |
| `terminal/glyphs` | Cell-aligned primitives, borrowed alpha rasters and bounded curve admission | C++ standard library |
| `graphics` | Image retention, budgets, upload assembly, placements and placeholders | Protocol and allocator types |
| `transport` | Bounded length-prefixed stream assembly | Allocator types |
| `input` | Compiled keymaps, physical ownership, sequence/repeat routing, mouse encoding and history text validation | Protocol and value types |
| `palette` | Prefix parsing, bounded fuzzy results, navigation identities and UTF-8 labels | Value types and shared scoring |
| `paths` | Runtime path pages, request identities, styled labels and bounded shell insertion | Protocol and value types |
| `suggestions` | Bounded command replies, request correlation and invalidation | Protocol and value types |
| `machines` | Saved profiles and JSON, remote discovery, validated shell commands and connection error policies | Protocol and allocator types |
| `links` | Recognition, logical cell traversal, hover and gesture ownership, file resolution and editor launch plans | Protocol and value types |
| `history` | Search ownership, bounded request tracking, paging, inspection and terminal-output text | Protocol and allocator types |
| `presentation` | Window/tab titles, tab-strip fitting, application/workspace marks and sidebar geometry | C++ value types and shared provider metadata |
| `config` | Lua configuration conversion and generated theme data | Shared Lua VM, local-module loader and validators |
| `core` | Colors, preferences and logical geometry | Value types |
| `qt` | QML models, event translation, text/image scene nodes, socket integration | Qt and the layers above |
| `platform` | Awake clock, socket peer identity, window identity leases, process environment and native window appearance | POSIX; AppKit on macOS; Qt window flags on Linux |

`DisplayMetrics` resolves chrome roles, window bands and sidebar/card geometry
in physical pixels before the Qt adapter projects them into logical coordinates.
The same value snapshot serves notification placement and workbench sizing.
It needs no Qt objects, application controller or dynamic storage. The original
Zig geometry matches 17,520 differential frames across eight densities; this
checks geometry rather than complete rendering.

The independent `AgentAcknowledgement` policy retains a single pane/generation
identity. Session reconciliation and committed agent snapshots acknowledge a
completed focused agent once, using the snapshot generation. Its original-source
oracle matches 6,505 operations. Live captures also verify the focused agent
returns to `ready` without another selection.

[Sidebar density validation](measurements/sidebar-density-validation.json) and
[paired captures](measurements/visual-parity/sidebar-density.json) retain these
checks. Complete root cards match at backing scales 1 and 2, and projects with
section headers match at scale 1: 221,575 RGBA pixels total. The scale-2 project
rectangle retains six different pixels in the system fallback branch symbol.
Other activity rows, full-window pixels and comparative performance remain open.

`fonts::Face` borrows font bytes and exposes physical metrics, borrowed shaped
runs and borrowed grayscale glyph masks without Qt. HarfBuzz objects are
created on the first shape call and reused. Callers that retain glyph data
copy it through their allocator. The independent `gui-font-shaping-probe`
target is included in clang-tidy. After building `gui-fonts`, compare it with
the original Zig face and raster procedures with:

```sh
python3 services/gui-cpp/tools/check_font_shaping.py --compiler clang++
python3 services/gui-cpp/tools/check_font_shaping.py --compiler clang++ --sanitizers
```

`--build-dir` selects another CMake build. The sanitizer option instruments
the C++ face and probe, while retaining the normal pinned dependency archives
for both languages. These checks cover the font layer; complete chrome,
font fallback, optical masks and full-window acceptance remain pending.

Default terminal text now shares this FreeType/HarfBuzz foundation and the
resident alpha-mask renderer used by chrome labels. Explicit cell baselines,
synthetic bold/italic and fallback cell bounds replace Qt's default glyph
rasterization. Window font discovery runs before rendering and skips unchanged
rows. Native optical rendering remains selectable; raster/cache failures retain
a Qt text fallback.

[Terminal-text validation](measurements/terminal-text-validation.json) retains
native Metal/Vulkan scene checks, Linux sanitizers and the unchanged 500-check
clang-tidy profile. [Paired captures](measurements/visual-parity/terminal-text.json)
match every pane pixel in two/four-pane scenes: 2,384,640 RGBA pixels, including
the unfocused text.

`TextRuns<Memory>` applies the original font's ligature input/context coverage,
cursor boundaries and ink-style boundaries. `RowTextLayout<Memory>` places each
result at its physical cell origin and retains its allocator-owned buffers.
Both components run without Qt, QML, an application model or a runtime connection.
Selection, faint ink, decoration order and all underline variants follow the
original renderer. Row caching includes cursor position even during its hidden
blink phase; a viewport resize removes hidden cells from ligature context.

[Cell-text validation](measurements/cell-text-validation.json) adds an
original-source row oracle and allocation-failure/reuse checks.
[Styled paired captures](measurements/visual-parity/terminal-cells.json) cover
26 variants at default spacing and at letter spacing 2 / line height 1.25.
Additional fonts, themes, densities, optical rendering, cache-pressure behavior
and comparative performance remain open.

`gui-text-scene-probe` exercises text-node creation, revision rebuilding and
retained repaint without an application controller, QML engine or runtime.
It measures CPU operations on the native render thread and hashes ordered
geometry and material values. The [text-scene experiment](measurements/text-scene-performance.md)
records a redundant-paint removal, alternating Release pairs, slower retained
repaint observations and the rejected noinline variant. These measurements
do not establish complete-frame or comparative Zig GUI performance.

The [native presentation comparison](measurements/frame-presentation.md)
adds a marker-verified `MTLDrawable.presentedTime` endpoint with actual VSync
controls. Current Qt loses every valid unloaded p50 pair against Zig in that
collection. A private eager-delivery prototype improves Qt's unloaded latency,
but remains outside production because its loaded and platform behavior are
not qualified. Its scoped static workbench pixels match the reference;
complete visual and performance acceptance remains open.

The later [guarded Cocoa experiment](measurements/cocoa-frame-policy.md) tests
timer-safe early delivery and retains five valid Qt/candidate pairs. It remains
private. Mapped input counters and native rejection traces reproduce expected
GPU colors with zero presentation timestamps in both clients; their cause is
not established, and rejected jobs remain excluded from timing acceptance.

The [frame pacing policy](measurements/frame-pacer.md) matches the original
GUI's intervals and pane-scoped grace over 32,174 stateful operations without
Qt or dynamic storage. Its interval resolver now bounds runtime negotiation
and applies `max_fps` to the shared animation clock, including reloads.
Per-pane admission now uses the controller integration described below.
The policy's standalone Linux Release and ASan/UBSan checks pass. The five
historical Cocoa attention waits are retained in that report; their test-loop
investigation follows below. Complete visual and performance acceptance is open.

[Terminal admission](measurements/terminal-frame-admission.md) now acknowledges
the frame actually synchronized by each terminal item. Hidden or unsynchronized
terminal content waits for rendering to resume; window bindings own independent
preparation snapshots through the application allocator. The runtime regressions
pass on Metal and Vulkan, including Linux ASan/UBSan. A fresh inspector capture
matches all 2,868,448 modal pixels. Native Cocoa hover/copy and activation
failures remain open, with the frozen baseline and diagnostic traces retained.

The [frame-wait investigation](measurements/gui-frame-waits.md) isolates delayed
scene preparation in a Qt-only manual-event-loop control. Test fixtures now use
a bounded local event loop, and the first hover-copy sleep waits on actual
terminal/link readiness. The production executable is unchanged. Metal attention
images match the original shader at all three tested factors; Linux Release and
ASan/UBSan checks pass. An isolated Cocoa readiness failure and earlier native
activation failures remain open, alongside complete parity acceptance.

The [window pacing adapter](measurements/window-frame-pacer.md) adds deferred
Qt update handling around the existing pure policy. Clock and window types are
injected through concepts and templates. Seven standalone Qt Core cases and
real Metal/Vulkan controls cover pending requests, pane-scoped grace, cadence
changes and teardown, including Linux sanitizers. The controller now uses this
component; its broader native admission qualification remains incomplete.

The later [controller integration](measurements/controller-frame-pacing.md)
connects Qt update admission, prepared-pane commits, queued input and output
wakeups to that adapter. Input observation compiles out with discarded effects.
Complete Metal and Vulkan assertions pass at all three tested factors; one
Vulkan sanitizer job still fails the unsuppressed Wayland leak gate. A fresh
inspector pair preserves all 2,868,448 modal pixels. Complete visual and
comparative performance acceptance remain open.

The [native readiness comparison](measurements/native-presentation-readiness.md)
now requires a verified positive initial presentation before the first warmup
key. Its 84-job original/previous-Qt/current-Qt collection retains 73 valid jobs
and 11 rejected controls. Current Qt loses every valid p50 pair against Zig.
Controller pacing wins all five valid loaded p50 pairs against previous Qt,
but only one of six tab pairs. Complete performance acceptance remains open.

The later [Cocoa dispatch experiment](measurements/cocoa-update-dispatch.md)
retains 127 valid jobs from 144 fixed attempts. It improves unloaded latency,
but loaded splits lose all seven p50 pairs against the preceding Qt build.
The candidate is rejected and production is restored to that preceding source.
Complete functional, visual and comparative performance acceptance remains open.

The [native palette navigation](measurements/palette-navigation.md) now opens
through `goto-picker`, searches contexts/tabs/agents and activates full target
identities. Matching and physical geometry run independently of Qt. Three
presented Cocoa navigation panel pairs match 3,563,520 pixels exactly.
The [action catalogue](measurements/palette-actions.md) is now generated from
the original 29 entries and exposes the 25 implemented actions, including
pane focus, tab selection/reordering and worktree cleanup. Key labels follow
both original host styles. The later [fallback alignment correction](measurements/palette-arrow.md)
removes the 54-pixel footer-arrow difference; four presented panel scenes
match 4,751,360 pixels exactly.

The [runtime path picker](measurements/path-picker.md) adds directory browsing
and quoted relative/absolute insertion, with bounded state and layout usable
without Qt. Its standalone oracle matches 9,989 original-source cases; the
empty picker has exact paired native pixels. Other measured picker states
retain file-icon differences. Machines, complete parity,
comparative performance and the historical native Wayland leak gate remain open.

The [suggestion palette](measurements/suggestions.md) now generates commands
through the runtime, rejects stale replies and pastes a reviewed command without
executing it. State, labels, geometry, preview wrapping and paste framing run
without Qt. The panel also runs in an isolated runtime-backed component fixture.
Its original-source oracle matches 8,397 cases, and eight presented Cocoa panel
pairs match all 6,389,760 compared pixels. Other themes, fonts, densities,
complete native interactions and comparative performance remain open.

The [machine components](measurements/machine-components.md) now preserve the
original saved profile format, stable identities, remote discovery and SSH error
policies without Qt. Their original-source comparisons cover 14,494 profile
cases and 15,638 remote cases on macOS and Linux, in Release and under
ASan/UBSan. Those comparisons cover the independent components; later window
and saved-profile checkpoints connect them to runtime clients. The machine
UI is wired by the later [machine UI](measurements/machine-ui.md) checkpoint;
actual SSH-host acceptance and complete native visuals remain pending.

The [machine profile store](measurements/machine-storage.md) adds atomic batches,
private filesystem storage and an independent Qt worker with polling, owned edit
requests and cancellable lock waits. Its component tests pass on both platforms
in Release and under ASan/UBSan. The later saved-profile adapter connects it to
runtime sessions; the later machine UI adds navigation, edit forms and setup
command tabs.

The [machine presentation lifecycle](measurements/machine-presentation.md) adds
deferred hidden startup, screen release, remembered pane restoration and bounded
workspace fallback to the platform-independent session. The later window and
saved-profile adapters extend this to one client per
enabled machine; the later machine UI adds picker actions. A
[production OpenSSH loopback run](measurements/machine-live.md) now covers
remote/local/remote input isolation with separate original runtimes. Additional
host platforms, live failure/recovery and complete SSH acceptance remain pending.
The [initial-machine launch](measurements/machine-launch.md) also wires
`--remote`/`--machine`, local-label selection, window-only pinning and remote
command/home adoption. Its real OpenSSH runs cover both selectors; five selected
Release and sanitizer groups pass. The native notification-focus investigation
retains its first failure and later traced passes without claiming its cause
is fixed. A later [retirement correction](measurements/notification-retirement.md)
returns keyboard ownership after a focused notification is removed by the
runtime, with window/machine/pane guards. Its current native suite passes 85
cases at that checkpoint; native exit leak detection remains open.
The later [global activity](measurements/machine-activity.md) composes every live
machine's agents, tasks and commands, retaining owned origin targets and cached
source revisions. Real SSH/native runs prove remote-card input isolation with
colliding pane IDs. Five selected Release groups and three core sanitizer groups
pass. Its current full native suite retains one notification-focus failure;
actual-position visual acceptance awaits the missing machine switcher/segment.
Read its manifest for the retained failures and narrower accepted scope. A
later [delivered-row removal](measurements/notification-removal.md) fixes the
routed focus failure when a card disappears before a disabled record reaches
QML. The current native suite has 86 passes and no QML warnings; native exit
leaks, machine chrome and global acceptance remain open.

```sh
python3 services/gui-cpp/tools/check_row_text.py --output-dir /tmp/telar-row-text
python3 services/gui-cpp/tools/capture_terminal_cells.py /path/to/zig/telar /tmp/telar-cell-capture \
  --cpp-gui services/gui-cpp/out/telar-gui \
  --config services/gui-cpp/measurements/visual-parity/expanded.lua \
  --capture --viewport 1600 1000 --samples 1 --rounds 1 --float-windows \
  --compare-region 288 42 1584 962
```

The capture adapter reuses the common runner and fixture lifecycle. It rejects
incomplete corpora or different pane grids and compares raw RGBA pixels in the
requested physical rectangle. The example excludes live footer telemetry and
requires the same native window environment as the other paired captures.
`--reference-build-dir` lets a sanitizer row probe use the normal build's pinned
archives for its Zig reference.

`Session<Memory, Transport, Clock, Effects>`, `Screen<Memory>` and `GraphicsStore<Memory>` take
their allocator by reference. They can run without a Qt application, a window
or a socket. Transport calls use templates and concepts. The optional
`willDetach` transport hook releases held input before its attachment ends;
it compiles away for transports that omit it. `TELAR_GUI_ALLOCATOR` selects
the application allocator at compile time. Tests use the existing runtime's
`BudgetAllocator` to check ownership and allocation failure paths.
The Qt application allocator must satisfy the runtime's `ConcurrentAllocator`
concept because configuration preparation shares it with a worker. The default
`SystemAllocator` satisfies that contract. A budgeted application allocator
must be shared through the existing `SynchronizedAllocator` wrapper.
`Effects` defaults to an empty discard implementation. Its template/concept
boundary sends owned host notices and semantic audio requests without Qt or
virtual dispatch. The Qt client supplies `ApplicationEffects`; standalone
session tests supply a recorder.

`AgentReplica<Memory>` validates snapshots before publishing metadata and status
clocks together. Two allocator-owned buffers retain string capacity between
revisions; allocation failure leaves the published revision unchanged. Clocks
follow the complete pane identity through reordering. Reconnection accepts a
replacement runtime's restarted revision counter and retires the old intervals.

`WorkspaceReplica<Memory>` owns project and tracked-worktree metadata separately.
It keeps the original project-first ordering, bounded path storage, command
outcomes and complete coordinator references. Staged replacement preserves the
published snapshot on allocation failure. Task workspaces remain available for
navigation without appearing twice in the project list; selecting one highlights
its source project while retaining the actual workspace context.

`ActivityOrder<Memory>` builds the original activity forest from borrowed source
replicas into caller-owned storage. It supports exact cross-source coordinator
identity, creator fallback, stale references, cycles, full/compact task selection
and unrepresented tracked commands without injected allocations or recursion.
The Qt application currently supplies only its local source; this generic
ordering layer does not implement remote machine connections.

`StatusAge` preserves fractional elapsed time across nondecreasing reports for
the same pane generation, state and provider. `AgentAnimation` supplies the
original 120 ms pulse, including its eight-bit frame rollover, and global wake
boundaries. Both work without Qt. `Session` selects its `MonotonicClock` through
a concept and template parameter. The default native adapter uses the same
awake clocks as Zig: `CLOCK_UPTIME_RAW` on Mac and `CLOCK_MONOTONIC` on Linux.

`NativeAgentStatus` carries its interval through QML as an opaque value, avoiding
JavaScript rounding of nanosecond integers. Each window shares one timer among
visible agent statuses, tab activity and notification presentation. Preparation
samples eligible components
at one timestamp; hidden and stopped observers request no periodic wakeups.
Offline agent statuses also park their timer deadlines.
Only changed labels and pulse alpha emit notifications. Independent cards and
lists need no application controller to animate.

The [agent-clock validation](measurements/agent-clock-validation.json) records
the original-source oracle, snapshot failure/reconnection checks, warmed
allocation counts, component rendering and platform checks. The oracle covers
clock arithmetic and pulse scheduling; it does not establish whole-window
timing, visual or comparative performance parity.

```sh
python3 services/gui-cpp/tools/check_agent_clocks.py --build-dir services/gui-cpp/out
```

`SidebarGeometry`, `WorkspaceRailGeometry`, `WorkspaceWindow` and `WorkspaceMark`
run without Qt or a runtime connection. QML chrome components receive models,
colors, typography and geometry through properties and emit selection signals.
`gui-chrome-test` creates the sidebar without the application controller and
checks its geometry, bounded delegate count and workspace-selection identity.

`TabCaption` composes automatic captions into caller-owned fixed storage and
borrows manual labels or eligible agent titles. It validates the displayed
directory name and truncates at a complete UTF-8 scalar. Tabs retain foreground
metadata through the injected allocator before their panes attach, including
when discovery precedes a creation reply. The tab strip and configurable window
title share the same application-name resolution.

`TabStripGeometry` fits at most 64 measurements into fixed arrays without Qt
or allocation. `TabStripLayout` measures covered IBM Plex Sans captions with
the original physical HarfBuzz advances and uses Qt for other font requests.
It coalesces changes through item polish and reconciles a separate model of visible tabs.
It keeps its layout anchor by identity while hovered and reveals selections
outside that window. `TerminalTabs.qml` receives its models, colors and
typography through properties. Its counter emits the nearest hidden tab's key;
the component needs no application controller or runtime connection.

`TabActivity` selects the original tab agent priority, dot/spinner state and
selected single-pane progress precedence. `ProgressMotion` retains the original
240 ms cubic interpolation and resets it when the pane attachment changes.
`ProgressRing` and `ProgressCapsule` emit bounded rounded figures through a
visitor without Qt or allocation. Their maximum counts are 66 and 69.
The indeterminate cosine implementation is a concept-constrained template
policy; its native precision choice stays in `platform/progress_cosine.hpp`.

`NativeTabActivity` uses the shared window clock and parks settled, paused and
error progress. Sampled values remain synchronous before drawing; its public
animation notification is coalesced onto the GUI event loop so callbacks can
close a window outside rendering. The hardware adapter retains one geometry
node per indicator, preserves physical coordinates through the shader and
reuses the existing rounded renderer for software drawing.

Build `gui-tab-activity-probe` to compare 5,512 records against original tab,
ring, capsule and motion procedures:

```sh
python3 services/gui-cpp/tools/check_tab_activity.py --build-dir services/gui-cpp/out --output-dir /tmp/telar-tab-activity-oracle
```

`NotificationCenter` owns four bounded notices without dynamic storage or Qt.
It preserves semantic identities across duplicate publications, refreshes their
lifetimes, samples 200 ms transitions and activates a notice at most once.
Agent snapshot commits retain transitions only for existing pane generations;
initial discoveries, rejected revisions and source replacement do not alert.
`AgentAlerts` publishes through concept-constrained callbacks and folds excess
changes into the original severity-ranked summary.

`NotificationText` wraps at words or whole graphemes and keeps an owned final
ellipsis after copying the value. `NotificationStack` selects at most two cards,
suppresses already visible pane targets and retains 180 ms stack motion.
These components accept borrowed data and measurements; experiments and tests
need no window, application controller or runtime connection.

The [stack and interaction validation](measurements/notification-interactions-validation.json)
adds 12,546 byte-exact original-source frames for placement, retargeting,
suppression, painter order and opacity at six densities. The same stream matches
on Mac, Linux and Linux ASan/UBSan. Card heights are injected into that oracle;
it does not replace text or raster comparisons.

The Qt adapter caches measured content independently of opacity and position.
Its cards use the shared native text and rounded renderers. They have separate
body/close controls, preserve keyboard focus on arrival and name HTTPS hosts
before opening them. A lifecycle timer wakes at transition endpoints and expiry;
the shared window clock samples presentation between them. Empty stacks park.
Actions run on press, including Return, Enter and Space, and return focus to the
current terminal. Explicit body/close keyboard navigation also works with the
native macOS focus policy. The close fill and ring retain the original separate
paint layers; action underlines use the physical row baseline during motion.

The [notification validation](measurements/notification-validation.json) records
7,246 original-source center operations and 30,888 body-wrapping cases, including
their Linux ASan/UBSan runs. Three paired Metal captures match 206,048 complete
card-and-shadow pixels across all four levels and two sidebar widths. This
acceptance covers those stable rectangles; other themes/densities, animated
pixels, complete interaction parity and comparative performance remain open.
Two additional [native hover captures](measurements/visual-parity/notification-interactions.json)
match 256,208 complete card-and-shadow pixels at backing scale 2, including the
action underline and the close highlight. Focused and animated pixel acceptance
remains open.
Configured notification bindings and callback effects use owned descriptors.
Compiled actions retain their original values after Lua table mutation; callback
descriptions remain usable after the registry reference retires. Routed dismissal
returns `applied` once and `NotificationNotFound` for a retired notice. The
[action validation](measurements/notification-actions-validation.json) covers
real runtime delivery, semantic navigation and focus retention.

The independent `SoundPlayback` and `NotificationPayload` components also have
[original-source coverage](measurements/notification-effects-core-validation.json):
10,943 operation results match on Mac and Linux, including Linux ASan/UBSan with
leak detection. This checks sound coalescing/policy changes and sanitized payload
bytes; it does not post a desktop notice or play audio.

Native host effects now use independent `SystemNotifier<Host, Memory>` and
`SoundPlayer<Host, Observer>` components. Delivery objects allocate lazily through
the supplied allocator and reuse completed storage. Qt retains ownership of its
internal process, timer and string allocations. Sound requests require the exact
current agent generation; configuration changes remove disallowed queued sounds.
The original one-active/one-queued policy keeps attention ahead of completion.
Native failures release admission, and desktop failures are not retried.

Platform command plans retain the original three-second timeout, macOS
`osascript`/`afplay` commands and Linux audio fallback order. Linux notices add
`--` before title and body so their contents cannot become helper options.
[Host-effect validation](measurements/notification-host-effects-validation.json)
retains 2,384 original-source command frames: 1,272 are byte exact; 1,112 Linux
notice frames differ only by that explicit option delimiter. It also checks the
original 240-ticket upper bound, allocator failure/reuse, process cancellation,
callback destruction, native helper results and remaining Mac hover, window
activation and link-copy failures.

`gui-host-effects-smoke` runs the same native components with a Qt Core event
loop, without QML, a window or a runtime. Its explicit `notify TITLE MESSAGE`,
`ready` and `needs-input` modes post a system notice or play the corresponding
sound. The Linux desktop check instead uses a private D-Bus service with the
[standard notification interface](https://specifications.freedesktop.org/notification/latest/protocol.html),
including real `notify-send` argument parsing and the three-second deadline.
It requires libnotify, PyGObject and `dbus-run-session`:

```sh
cmake --build services/gui-cpp/out --target gui-host-effects-smoke gui-host-commands-probe --parallel 2
python3 services/gui-cpp/tools/check_host_commands.py --output-dir /tmp/telar-host-command-oracle
python3 services/gui-cpp/tools/check_notification_desktop.py --output-dir /tmp/telar-desktop-check
```

```sh
python3 services/gui-cpp/tools/check_notification_center.py --build-dir services/gui-cpp/out --output-dir /tmp/telar-notification-center-oracle
python3 services/gui-cpp/tools/check_notification_text.py --build-dir services/gui-cpp/out --output-dir /tmp/telar-notification-text-oracle
python3 services/gui-cpp/tools/check_notification_stack.py --build-dir services/gui-cpp/out --output-dir /tmp/telar-notification-stack-oracle
```

[Tab validation](measurements/tab-activity-validation.json) records the source
oracle, 120 original-shader poses, native/software component runs and remaining
sanitizer failures. [Live comparisons](measurements/visual-parity/tab-activity.json)
retain exact selected pills and complete tab bands at two sidebar widths.
Pane header progress, hidden-counter pixel comparisons, complete interactions
and whole-window/performance acceptance remain open.

`ApplicationMark` resolves built-in executable aliases, display names and
terminal/editor/git glyphs without constructing the runtime's manifest table.
The runtime and GUI share the executable suffix matcher and provider metadata.
`ArtworkResize` reads borrowed RGBA views and writes into caller-owned storage,
using the original area filter or bilinear interpolation before premultiplication.
`ProviderMark` retains its scene-graph texture between paints; provider, color
and scale changes rebuild it. Hover dimming uses item opacity. The reusable
`ApplicationMark.qml` component selects artwork or glyphs through properties.
Ancestor changes and reparenting refresh a separate pixel-alignment transform,
keeping image geometry and texture unchanged during movement.

`ChromeText.qml` uses `NativeChromeText` for supported labels. GUI-thread
shaping copies glyph positions into allocator-owned storage. The render
thread owns separate font faces and a per-window mask cache; scene nodes keep
their texture references alive through destruction. Textures are initialized
before nodes enter the live scene graph. `AncestorGeometry` shares movement
and reparenting observation with provider marks.

The renderer reuses Qt Quick's public
[image atlas](https://doc.qt.io/qt-6/qsgtexture.html#texture-atlases) and the
terminal curve mask material. Hardware labels group geometry by atlas texture;
color and movement updates retain their nodes. Clipping and truncated-caption
opacity follow the original glyph rectangles, without an intermediate label
texture. The software backend caches two color variants per glyph and clips
at physical pixel centers. Mask uniforms correct the projection when Qt rounds
the framebuffer extent at fractional density, preserving the masks' physical
pixel size. This uses the public
[render state](https://doc.qt.io/qt-6/qsgmaterialshader-renderstate.html).
Each window/font-set mask cache is bounded by 4 MiB of aligned alpha storage
and 4,096 entries. Unsupported faces, layouts and cache admission failures
retain the Qt text path. Complete fallback coverage, optical
chrome rasterization, complete density geometry and comparative performance
remain acceptance requirements. See [validation](measurements/chrome-text-validation.json).

`ChromeIcon.qml` now uses `NativeChromeIcon` for resident glyphs. The preferred
Plex face precedes the configured primary, embedded text and symbol faces.
Immutable `FontAsset` bytes resolve before rendering; each thread creates
its own FreeType/HarfBuzz state. Family/style changes rebuild that source,
while movement and color changes retain glyph geometry and masks.

`IconLayout<Memory>` accepts a font provider through concepts and copies ink
positions through the supplied allocator. It groups preferred-face graphemes,
fits fallback ink to the primary grid and exposes its quads without Qt or an
application controller. `IconPlacement` performs the final ink-box fit.
The Qt adapter samples at twice the physical label height and uses the
original 0.85 size ratio.

The shared glyph cache uses nearest sampling, as the original Metal and Vulkan
glyph paths do. Icons have a separate material variant that resolves samples
near texel boundaries consistently by applying sixteen binary32 epsilon steps
in normalized coordinates. This avoids one-pixel translation changing the
sampled texel across the tested backends. The software path uses the public
`QSGImageNode` factory so its filter is applied. The retained geometry helper
and caches are shared with chrome text.

[Icon validation](measurements/chrome-icon-validation.json) records exact
Metal comparisons against two original icon crops, a one-channel-level bound
when comparing software/OpenGL composition with those Metal crops, movement,
font reload, separate thread faces, material isolation and standalone QML.
The scale cases retain physical icon sizes; they do not establish complete
GUI typography at every density. The full-window comparison still differs in
five pixels of one status icon, rounded card edges, footer and other details.
Installed-font discovery, procedural/custom-icon completeness, optical chrome
rasterization and comparative performance remain open.

The default footer uses standalone `MetricsGroup`, `BarMetric`, `BarSparkline`,
`BarBattery` and `BarBadge` components. It shows the original CPU and memory
glyphs, nine recent CPU columns, decimal `GB` labels, battery shape and
warning/danger colors. Missing host samples and absent batteries stay hidden.
TLS and dismissible diagnostic badges reserve space at the right edge.

`HostMetrics` accepts newer runtime revisions and retains CPU samples in the
fixed 32-entry `CpuHistory`. Both helpers work without Qt or a window.
`BarMetrics` formats through bounded value storage and resolves named palette
roles. A dedicated Qt notification updates the metric projection without
rebuilding workspace, tab, pane or agent models. Disconnect clears the runtime
replica and accepts a replacement runtime's restarted revision counter.

The [footer validation](measurements/footer-validation.json) records the
original-source value/history oracle, component tests and paired captures.
These captures use live host telemetry, so differing metric values and sample
counts are expected. Configured slot sources, dynamic/static custom content,
complete fitting/overflow and all widget density/theme states
remain unported or unverified. The default metric group does not establish
configurable-bar or full-window parity.

Prefix and copy modes now replace that metric group through `ModeBar`.
`ModeHints` queries the effective router for the eight original actions in
their original order, including the first configured alias for an action.
`ModeBarLayout` owns bounded label values and computes chip/hint geometry
without Qt. Its original-source oracle checks whole-token fitting, key
formatting, named colors and geometry across 5,696 requests.

`NativeCellText` uses the configured terminal grid and primary face. Its
allocator-owned `CellTextLayout` shapes individual graphemes, retains the
complete advance and selects whole-cluster prefixes when the width changes.
It shares the existing retained text scene and resident glyph masks; cache
keys now distinguish synthetic bold and italic styles. GUI and render threads
keep separate mutable font state. Missing clusters now use the window's bounded
installed-font discovery queue. Each component retains its configured primary
face while sharing discovered fallback faces and immutable collection snapshots.
Repeated alternate-primary requests reuse the same collection. Property and
layout notifications may retire the item without further access to it.
[Cell-font validation](measurements/cell-font-fallback.md) records the regression,
standalone/native checks and one complete inspector modal matching the original
pixels, including the continuation arrow. Full font-cascade equivalence remains
open.

[Native resize capture validation](measurements/native-resize-capture.md) corrects
an observation defect: captures now require presentation after an actual native
size change. Drawable adoption no longer waits for the GUI thread. Qt-only
controls and paired inspector captures retain exact full images; the earlier
intermittent failures and general resize acceptance remain open.

[Window restoration validation](measurements/history-window-restore.md) exercises
real history replacement and frame admission across hide/show on both platforms
and accepted Cocoa minimization at three scales. Linux sanitized runs preserve
those checks and explicitly omit minimization declined by the compositor.

[Mode validation](measurements/mode-bar-validation.json) records native mode,
text, icon and binding tests on both platforms at three scales, scoped
sanitizer checks and original prefix/copy captures. All mode text matches
without registration in those initial captures. The later
[rounded-shape captures](measurements/visual-parity/rounded-rectangles.json)
remove the 28 rounded-chip differences: both complete mode footers and all four
sampled selected-card borders now match exactly at backing scale 1. These
Debug captures do not establish full-window, full-density or comparative
performance parity.

`RoundedRectangle` exposes the original signed-distance coverage and color
mixing without Qt or allocation. `NativeRoundedRectangle` keeps geometry in the
scene graph, carries shape/color values in vertices and shares one material so
Qt can batch different shapes. The software node shades scanlines directly;
for axis-aligned shapes it samples the two edge bands and one constant central
span per row, without caching a full-area image. Selected cards retain the
original separate fill/ring passes and one-physical-pixel ring.

The [rounded-shape validation](measurements/rounded-rectangle-validation.json)
records 17 original-shader cases at three scales, clipping/restoration checks,
60 component invocations across Mac/Linux, scoped sanitizer checks and the live
pairs. Metal atlas pixels are exact. Software/OpenGL allow one channel level
per composited layer, up to two only where translucent shapes overlap. Full
same-backend Linux reference captures, theme/density states and performance
acceptance remain open. The
[fixture instructions](tests/fixtures/shapes/README.md) describe the independent
Mac-only reference tool; consuming the fixture needs neither that tool nor a
full application controller.

`TextFit` accepts a compile-time measurement dependency and caller-owned
256-byte output. Text that already fits borrows its source. Truncation uses
the original grapheme estimate and decrement rule; a fixed prefix table
avoids rescanning prefixes that exceed the output capacity. `GraphemeCursor`
reuses the pinned Ghostty segmentation API and the original 16-codepoint
window. Neither helper depends on Qt or allocates storage.

`NativeChromeText` retains both the complete and fitted glyph runs. Resizing
does not reshape the complete label or change its implicit width. Covered
right-elided labels use the same native masks and baseline as other chrome
text; unsupported faces/layouts keep the existing Qt fallback.

Build `gui-text-fit-probe` and run:

```sh
python3 services/gui-cpp/tools/check_text_fit.py --output-dir /tmp/telar-text-fit
```

The runner compares unchanged Zig fitting/iterator sources with the C++
helpers. Its isolated measurement facade uses the original shaping function
with one selected face, and forwards segmentation to the pinned Ghostty C
API. [Validation](measurements/text-fit-validation.json) distinguishes these
32,136 byte-exact records from rendered-label checks and window samples.
It does not establish original font fallback order or complete text parity.

`TextLayout<Memory>` now applies the original resident font order to each
grapheme run. Preferred-face runs keep contextual shaping; other faces retain
the original primary-cell advance and ink fitting. Unknown glyphs temporarily
use the configured primary face. A missing symbol no longer sends the whole
label through Qt, so surrounding Plex text retains its masks and fitting.
`FontRuns`, `GlyphTransform` and `InkBounds` are shared with icon rendering.
These helpers accept compile-time font dependencies and explicit allocators,
and can run without Qt or an application controller. Covered labels store
their single span inline; repeated mixed shaping reuses its allocated buffers.

`WindowFontCatalog` owns bounded discovery requests for one window. Native
CoreText or Fontconfig matching and file loading run on a worker; the GUI
thread adopts immutable collections with up to eight additional monochrome
faces. Generation checks discard results from replaced configurations.
Render and GUI threads retain separate mutable FreeType/HarfBuzz faces, while
scene nodes retain the immutable collection they used. Closing a window joins
its worker, including when a discovery callback destroys that window.
Alternate-primary collections are cached weakly and retired after adoption or
configuration changes. Requests can use a component's collection without
replacing the window's configured primary face.

Build `gui-font-cascade-probe` and run:

```sh
python3 services/gui-cpp/tools/check_font_cascade.py --build-dir services/gui-cpp/out --output-dir /tmp/telar-font-cascade
```

The runner executes the original `GlyphAtlas`, `FontSet`, `FontRuns` and
`TextFit` with real bundled faces. It compares 12,132 measurements, span
selections, fitted labels and ink transforms across three configured primary
faces. The [cascade validation](measurements/font-cascade-validation.json)
separates these calculations from discovery/rendering checks and the
[paired task facts](measurements/visual-parity/README.md#mixed-font-task-facts).
Procedural cells, color fonts, installed fallback for icons/cell text,
optical chrome and full visual/performance acceptance remain open.

`AgentCardGeometry`, `AgentStatusPresentation`, `AgentCardLabels` and
`AgentOrder` calculate card rows, status words/glyphs/colors, reported ages,
context labels and base project/attention order without Qt or a runtime.
Agent snapshots retain the manifest name separately from the display name,
the typed provider, workspace label, configured glyph and blocked reason.
The existing injected allocator owns their copied strings.

`AgentCard.qml` and `AgentStatus.qml` receive records, typography, colors and
geometry through properties. They emit selection by identity, reserve the
original three rows, distinguish selected/hovered cards and drop status
duration before its word and icon. `ActivityList.qml` instantiates visible
cards with the original spacing and project breaks. The shared QML fixture
can create these components without the application controller or a runtime.

Build `gui-agent-presentation-probe` and run:

```sh
python3 services/gui-cpp/tools/check_agent_presentation.py
```

The runner compares the original Zig status, age, pulse and card geometry
functions with the linted C++ probe. It supplies row heights directly and
represents palette colors by role names. It does not prove complete fleet
ordering or rendered equality. [Validation](measurements/agent-card-validation.json)
records the component and snapshot checks, native graphics runs, sanitizer
scope and remaining pixel differences. The later
[clock validation](measurements/agent-clock-validation.json) covers advancing
ages and shared pulses.

`TaskCard.qml` displays full or compact tracked tasks; `CommandCard.qml` displays
tracked commands without an agent. They share selection, physical-pixel borders,
hover and coordinator guides with `AgentCard.qml` through `ActivityFrame.qml`.
Full tasks retain facts, emphasized titles, activity/final-message text and the
bounded eight-cell plan. Compact tasks show the original coarse age and dim
ready titles. A shared window clock updates these ages between snapshots and
parks retired or hidden components. Commands navigate through their materialized
workspace identity and disable navigation when offline.

Build `gui-activity-probe` and `gui-task-labels-probe`, then run:

```sh
python3 services/gui-cpp/tools/check_activity_order.py --build-dir services/gui-cpp/out
python3 services/gui-cpp/tools/check_task_labels.py --build-dir services/gui-cpp/out
```

The [activity validation](measurements/activity-validation.json) records 1,261
original-source ordering/replica cases and 2,301 task-label/plan cases, including
the full 17-source bound and a 1,088-node cycle. Native component checks cover
full/compact transitions, coordinator guides, plan colors, command selection
and actual model-to-list composition on Mac and Linux at three scales. These
checks alone do not establish paired original task-card pixels or live runtime
integration. The later [paired task capture](measurements/visual-parity/README.md#tracked-tasks-and-commands)
uses real isolated worktrees and hooks on macOS: titles, plan, compact cards,
command card and coordinator guides match at their original coordinates.
The later mixed-font revision preserves the surrounding text and discovers
the missing branch symbol per grapheme. Complete card pixels, remote
connections, favicons, peeks, scrolling/selection behavior,
font fallback and full visual/performance acceptance remain open.

`ProjectActivity` calculates each project's worktree, working, finished and
waiting counts from the existing replicas. It reuses the shared attention
order to choose the indicator color. The summary keeps the original symbols,
spaces and 256-byte bound; a summary that exceeds the bound falls back to the
project path. Capacity is checked before appending that path, so overflow does
not construct an exception. Caller-owned text storage and borrowed replica
views let the calculation run without Qt or allocation through the injected
allocator. `LabelText` shares the existing text-fitting bound with task labels.

`ProjectRow.qml` renders the summary and `! N` indicator independently of the
application controller. Attention reserves title space while the detail line
keeps its full width. The row retains original inactive ink, selection, hover
and identity-based activation, and `WorkspaceList` supplies its model records.

Build `gui-project-activity-probe` and run:

```sh
python3 services/gui-cpp/tools/check_project_activity.py --build-dir services/gui-cpp/out --output-dir /tmp/telar-project-activity-oracle
```

[Project validation](measurements/project-activity-validation.json) records
2,590 comparisons against unchanged original summary/attention functions and
the actual workspace replica. Its text/color recording adapters do not prove
font measurement or rasterization. Separate [paired project rows](measurements/visual-parity/README.md#project-progress-and-attention)
cover the original Metal pixels at narrow and wide sidebar widths.
Remote source composition, favicons, previews and complete project interaction
states remain open.

The keyboard router publishes prefix changes separately from session/model
refreshes. Tab chips show their global one-based number while the prefix waits,
including when earlier tabs are hidden. Switching between marks and numbers
preserves the fitted widths, overflow counter and hover anchor.

`WorkbenchGeometry` and `TerminalGrid` keep launch and resize calculations
independent of Qt. The Qt adapter supplies the current physical cell dimensions,
display scale, workbench bounds and pane chrome. New tabs use the complete
workbench even after a child pane has resized. Split planning fits both children
before changing membership, resizes the source PTY before creating the process,
and restores its current geometry after delivery or runtime failure. Late
confirmations preserve the active tab and cannot recreate a removed tab.
The shared fitter rejects invalid or sub-cell extents and bounds dimensions
and frame storage. It multiplies logical extents by display scale before dividing
by physical cells, preserving complete columns at fractional scales.

`PaneLayout` now owns typed `CellRectangle` placements. It partitions integer
cells, applies the original conditional gutters and reserves one complete cell
on each framed edge. Prospective splits use those same content rectangles and
reject regions that cannot retain the original minimum. Directional focus uses
the original edge/center ranking; keyboard resizing preserves every subtree's
minimum extent. `WorkbenchGeometry` converts the resulting cells to pixels once
the presentation needs them. The terminal widget uses those content bounds
directly, so it shares the launch-size calculation instead of reserving a second
pixel header or border.

The [cell-grid validation](measurements/pane-grid-validation.json) compares 5,700
unchanged original layout frames, including fullscreen, focus, prospective
splits and resize results. [Two paired Metal scenes](measurements/visual-parity/pane-grid.json)
with two/four panes match every visible PTY size and marker position. The
complete focused marker pane matches 596,160 RGBA pixels per scene. Cell bands,
trailing frame extensions, the one-physical-pixel outline, unfocused dim and
border press-to-focus use the same layout. Text-bearing unfocused panes still
differ; these captures establish no general terminal-text or performance parity.

Fullscreen panes use a bottom strip with application marks, pane indices,
the focused program/status, hidden-pane focus targets, progress and an exit
control. Names compact before the entry window moves around the focused pane.
`FullscreenStripGeometry` runs without Qt and keeps bounded storage for 64
entries. The Qt adapter measures through the existing font cascade, and QML
loads the strip only while fullscreen is visible. A pending reattachment now
delivers the latest requested viewport after confirmation, including a size
changed during that request. Rejected resize admission preserves its prior size.

[Fullscreen validation](measurements/fullscreen-strip-validation.json) retains
the original-source oracle, native component/runtime checks and sanitizer scope.
[Paired captures](measurements/visual-parity/fullscreen-strip.json) cover default,
progress and compact narrow strips. Other themes/densities and Linux paired
window pixels remain unaccepted.

```sh
python3 services/gui-cpp/tools/check_fullscreen_strip.py --output-dir /tmp/telar-fullscreen-oracle
python3 services/gui-cpp/tools/capture_fullscreen_strip.py /path/to/zig/telar /tmp/telar-fullscreen-capture \
  --cpp-gui services/gui-cpp/out/telar-gui --with-progress \
  --config services/gui-cpp/measurements/visual-parity/expanded.lua \
  --viewport 1600 1000 --panes 4 --samples 1 --rounds 1 --float-windows
```

The capture adapter preserves the common runner's grid, viewport, foreground
and GPU-completion checks. Each fixture runs in a separate foreground process
group so the runtime retains its OSC progress as a job report. Receipts verify
those groups. Source snapshots are retained with each raw capture. Timing
samples remain diagnostic because the build modes are unmatched.

Pane headers use the independent `PaneHeaderGeometry`, `PaneStatusChip` and
`PaneProgressPresentation` components. They retain the original display index,
foreground program, lowercase status words, hour-based working age, attention
priority and full/compact progress fitting. `PaneHeader.qml`, `PaneStatusChip.qml`
and `PaneProgress.qml` need records, colors and typography rather than an
application controller. They share the existing window clock and resident
text/shape renderer. Plain shells show no status chip, and the projection rejects
agents from another attachment or tab.

The [pane-header validation](measurements/pane-header-validation.json) compares
14,506 original-source geometry and label records. A
[paired Metal capture](measurements/visual-parity/pane-headers.json) matches the
focused first pane's complete program-label band, 11,856 RGBA pixels at unchanged
coordinates. That earlier paired runner rejected split geometry: Zig reported
70x44 cells per pane and Qt 72x45. The later cell-grid port closes this specific
difference. Later attention-ring and fullscreen-strip captures extend that
coverage. Graphics-pause routing has the additional checks described below. Other
density/theme scenes remain open; the earlier capture alone does not accept
complete status/progress pixels.

`GraphicsPauses` keeps the original per-pane retry window, exponential backoff,
focus acceleration, snapshot completion and bounded eviction without Qt or heap
allocation. `LimitReports` owns the fixed diagnostic ledger and paced reports.
`GraphicsStore` distinguishes resource limits, revision drift and malformed
transfers; deletes continue releasing credits during a pause. The session asks
for recovery before accepting a permanently incomplete replica, and the Qt
adapter schedules the earliest retry independently of window exposure. Pane
records carry the actual pause marker into the existing header layout.

The graphics recovery checks compare 13,535 original-source pause operations and
4,180 original limit-ledger operations byte for byte. The independent socket
fixture drives the production session, projection, QML header, deadline timer and
connection recovery. Run the selected checks with:

```sh
cmake --build services/gui-cpp/out --target gui-graphics-recovery-test gui-graphics-recovery-scene-test gui-graphics-pauses-probe gui-limit-reports-probe
ctest --test-dir services/gui-cpp/out --output-on-failure -R '^gui-graphics(-recovery(-scene)?)?$'
python3 services/gui-cpp/tools/check_graphics_pauses.py --output-dir /tmp/telar-graphics-pauses-reference
python3 services/gui-cpp/tools/check_limit_reports.py --output-dir /tmp/telar-limit-reports-reference
```

These recovery checks do not establish the complete image lifecycle or
comparative performance. Retention and window resource checks follow below.

`GraphicsStore` now retires generations without discarding metadata still named
by a placement. Unreferenced pixels release their credits at the incoming
header; completed superseded generations cannot start another upload. The
presentation cache owns its existing texture while the replacement arrives.
Placement deletion uses the runtime virtual identity. Direct catalog calls also
validate identities and dimensions before changing existing resources.

`ImageSourceRect` and `ImageDisplayBox` resolve source pixels, clamped offsets,
saturated sizes and rounded aspect ratios without Qt. The Qt adapter projects
that physical box into logical coordinates. The independent
`ImageTextureCache<Resource>` remains available to tests and experiments with a
templated upload callback and optional integer handles. The production renderer
now uses the shared window resource table described below. Placeholder fragments
sample the resolved whole stand-in rather than stretching it once per cell.

The [retention validation](measurements/graphics-retention-validation.json)
compares 49,809 original catalog operations and 2,880 original display-box/UV
records. Seven selected tests pass on macOS and Linux; the new image scene,
real-runtime Kitty rendering and six selected Linux sanitizer targets have
additional coverage. Native captures cover RGB, straight alpha, changed aspect
ratios, cropped placeholders, oversized textures and reattachment at scales
1, 1.25 and 2. The cross-platform image-region comparison is C++ Metal versus
C++ Vulkan; it does not accept Zig/Qt pixels or complete windows.

```sh
cmake --build services/gui-cpp/out --target gui-graphics-retention-test gui-graphics-retention-scene-test gui-graphics-store-probe gui-graphics-geometry-probe
ctest --test-dir services/gui-cpp/out --output-on-failure -R '^gui-graphics(-retention(-scene)?)?$'
python3 services/gui-cpp/tools/check_graphics_store.py --output-dir /tmp/telar-graphics-store-reference
python3 services/gui-cpp/tools/check_graphics_geometry.py --output-dir /tmp/telar-graphics-geometry-reference
```

`runtime.graphics.pane_mib` and `global_mib` configure the runtime, as in Zig.
They are not GUI catalog settings. The GUI retains the original fixed CPU limits.
The window resource table combines retained CPU credits with resident RGBA texture
credits for admission; native upload leases and shared-memory delivery remain open.

Catalog construction and detach now issue a process-wide `GraphicsLifetime`.
Both the generic texture cache and Qt scene compare that identity, so destroying
and reconstructing a catalog in the same storage cannot preserve its old texture
or skip scene synchronization. The [lifetime and residency validation](measurements/image-residency-validation.json)
retains the failing pre-fix regression and the new native reconstruction case.

`ImageResidency<Resources>` is the Qt-independent policy for 512 stable texture
handles. Its fixed table owns admission, in-flight limits, ready and failed
generations, spare reuse, retirement, idle expiry and eviction. Resource release
uses a template dependency constrained by a concept. Tests and probes instantiate
it with integer-handle effects, without a window, pixel buffers or a graphics
driver. The original-source check compares 29,505 operations, including the
release order and every occupied row's state.

`WindowImages` connects that policy to one resource table per `QQuickWindow`.
Panes compete for the same admission budget, and views of one catalog share its
texture. `ImageResource` owns the Qt texture and pending pixel copy, detaches
draw nodes before releasing or overwriting their texture, and rewrites native
textures when a same-size spare is reused. Catalog and generation checks protect
cached handles from slot reuse. Four upload starts are admitted per frame;
pending visible scenes request another frame until that bound clears. Scenes
blocked by protected resident images park until resources or CPU credits change.

One deadline timer expires hidden-pane images and spares. Visible images retain
their textures at an idle deadline. A temporary render stop preserves resources
while the window is still requested as visible; hiding or minimizing the window
releases them immediately. That hidden-window release timing differs from the
original idle policy and has no comparative performance acceptance.

The [window resource validation](measurements/window-images-validation.json)
records shared admission, autonomous upload waves, fan-out to two views, spare
rewrites, visibility and idle behavior. Allocation counters check actual native
texture creation and reuse. The adapter currently completes admission after
native allocation and owned pixel staging, before GPU transfer completion.
Staging copies are outside the semantic admission credits; these checks do not
establish a physical process-memory bound. Asynchronous completion/failure,
upload leases, shared-memory delivery, broader Zig/Qt image pixels and
comparative performance remain pending. Placement selection is covered by the
later validation below.

Nine selected normal targets pass on macOS and Linux. The standalone resource
scene has 18 Qt Test entries and passes on Metal and Vulkan at scales 1, 1.25
and 2. Fifty-four C++ image-region pairs compare 483,840 pixels with a maximum
channel difference of two levels; two full-window size differences retain only
black padding outside the declared image item. Eight Linux software-renderer
targets pass with ASan/UBSan and unsuppressed leak detection. The additional
Vulkan sanitizer process completes all assertions but fails on 864 leaked bytes
in Wayland allocation stacks. A separate 16-window Qt-only rectangle fixture
reproduces those stacks without Telar code. That native sanitizer gate remains
failed; the record retains both reproductions and the clean single-window probes.

The separate [Zig/Qt image pair](measurements/visual-parity/kitty-images.json)
matches all 1,192,320 RGBA pixels in the existing declared workbench region on
macOS Metal, at scale 1 with the shade theme. Four inline Kitty images cover
RGBA, RGB with unaligned rows, straight alpha and source cropping in an unfocused
pane. Both clients use the original runtime and the same configuration; each
fixture receives four successful protocol replies. The unchanged native probe
passes focus, keyboard, geometry, marker and GPU-completion checks. Earlier
fixture reds confused its marker centroid; the accepted corpus separates those
colors and retains the failed attempts. Other scales, Linux pairs, focused image
panes, dynamic transitions and comparative performance remain open.

`ImageDrawBudget` now enforces the original 2,048-image-quad bound across the
whole window. `WindowImages` admits retained scenes in scene-graph paint order
after synchronization. Per-scene construction follows the original layer order:
below backgrounds, below text, placeholder fragments, then above text. Fully
clipped geometry consumes no draw node or draw credit; partial clipping adjusts
its source coordinates. Viewport changes invalidate cached geometry. Qt opacity
nodes preserve excluded draws for later admission through
[subtree blocking](https://doc.qt.io/qt-6/qsgnode.html#isSubtreeBlocked).

The [draw-budget validation](measurements/image-draw-budget-validation.json)
compares 24,132 observations against the unchanged original renderer admission
and clipping functions on macOS, Linux and Linux ASan/UBSan. Admission, counts,
handles and destination values match exactly. Normalized UV arithmetic differs
by at most 0.00000011920928955078125. The existing 2,880 display-box/UV records
still match. Native image scenes now have 21 entries at each of three scales;
81 Metal/Vulkan capture pairs compare 1,666,560 pixels with no channel difference
above two levels. Nine named states cover retained view ordering, placeholder
saturation and clipping, without depending on retry-expression evaluation counts.
The macOS Zig/Qt workbench pair still matches all 1,192,320 pixels exactly.

Quota-blocked views park while visible textures remain protected. Releasing the
last visible reference wakes them before idle expiry. The record retains both
the continuous-retry regression and the missing-wakeup regression. Fifteen
affected translation units pass the unchanged 500-check clang-tidy profile, and
seven selected headers pass clangd. Eight selected Linux software-renderer
targets pass with ASan/UBSan; the final native process passes its 21 test entries
but still fails leak detection on the previously reproduced Wayland allocation
stacks. No suppression was added.

`ImagePlacementSelection` adds the separate global metadata bound before texture
resolution. Its fixed heap keeps the highest 2,048 placements by layer and
`z-index`; placeholders compete below text regardless of their `z-index`.
Multiple views of a catalog consume one metadata entry per placement. Entries
without image metadata, valid source extents or a nonzero display box do not
compete. Discarded placements do not resolve textures or protect cached handles.

`WindowImages::preparePlacements` consumes borrowed view/catalog descriptions on
the GUI thread and retains identities and revision stamps. The application
prepares it after animation and during terminal polish, so a direct window grab
also sees current metadata before scene synchronization. A standalone renderer
must prepare its source snapshot before synchronization or synchronous capture.
Unchanged metadata reuses the plan; changed membership updates visible owners
before synchronization and invalidates retained scenes. The 64-source stamp
cache has a rebuilding fallback rather than a functional source limit.

Entering overflow reports `gui.images.placements_per_frame` through the shared
session limit ledger, with the original warning title, noun and requested count.
Returning below the bound resets the entering latch. Session reporting retains
its notification/report intervals and failed-delivery recovery.

The [placement-selection validation](measurements/placement-selection-validation.json)
compares 185 frames and 479,532 candidates with the unchanged original heap and
layer functions. Selected identities, dropped counts and membership changes
match byte for byte for the same candidate traversal. The original global hash
map and the C++ per-pane stores can traverse equal priorities differently; exact
visual acceptance of that overflow case remains open.

Nine selected normal targets pass on both platforms. The standalone image scene
passes its 22 Qt Test entries on Metal and Vulkan at scales 1, 1.25 and 2, with
three original-runtime Kitty entries at each scale. Ninety C++ capture pairs
compare 2,392,320 pixels with a maximum channel difference of two levels and
black padding. The repeated macOS Zig/Qt pair matches 1,192,320 pixels exactly.
Seventeen affected translation units pass the unchanged 500-check clang-tidy
profile; the final polish change passes its two-unit recheck. Seven selected
headers pass clangd. Eight Linux software-renderer targets and the selector
oracle pass ASan/UBSan with unsuppressed leak detection. The native process
completes all 22 entries but still fails on the previously reproduced Wayland
allocation stacks; that gate remains failed.

The draw bound does not bound all retained nodes or staging memory. Native
completion/failure, upload leases, shared-memory delivery, clean native Linux
leak acceptance, broader paired pixels and comparative performance remain open.

```sh
cmake --build services/gui-cpp/out --target gui-image-residency-test gui-image-residency-probe gui-graphics-geometry-probe gui-placement-selection-probe
ctest --test-dir services/gui-cpp/out --output-on-failure -R '^gui-image-residency$'
python3 services/gui-cpp/tools/check_image_residency.py --output-dir /tmp/telar-image-residency-reference
python3 services/gui-cpp/tools/check_image_draws.py --output-dir /tmp/telar-image-draws-reference
python3 services/gui-cpp/tools/check_placement_selection.py --output-dir /tmp/telar-placement-selection-reference
```

`AttentionFades` owns a fixed table keyed by pane and client attachment, with
the original linear 360 ms transition and frame pruning. `PaneAttentionGeometry`
supplies the physical one-pixel inset, scaled border and clamped radius without
Qt. `NativePaneAttention` renders through the resident rounded-shape renderer;
QML creates it only for an unfocused, framed pane needing input. It shares the
window clock with status chips, tab activity and notifications. Settled and
hidden observers leave no animation deadline. First exposure starts a new
ring's fade; hiding the window retains the identities of previously painted rings.

The [attention validation](measurements/pane-attention-validation.json) compares
145,690 original-source operations and four original Metal-shader fade phases.
The component tests select a controlled awake clock at link time, without a
production clock setter. They exercise real frame callbacks and rendering,
including observer replacement, generation changes, hiding, window transfer
and destruction. A child mode in the integration executable verifies its pane
descent and sends the real report protocol, so the same GUI case runs with
either runtime without depending on its CLI commands. The
[paired captures](measurements/visual-parity/pane-attention.json) retain complete
two/four-pane workbenches and the differences outside those accepted regions.

The Qt adapter observes its bound window's dimensions directly. Binding another
window removes the previous callbacks; binding the current window preserves
its subscriptions. A weak Qt pointer tracks destruction, and queued frame
delivery carries the binding generation. Only a registered terminal belonging
to that window can acknowledge a frame. Replacing a window and returning to it
cannot authorize an earlier queued delivery.

Window density events update workbench metrics, while each `TerminalItem`
observes Qt's item density notification independently. Both use Qt Quick's
effective device pixel ratio, including an explicit render target. Font
measurement, rendering, links and pixel mouse reports share that scale.
Standalone window tests require neither QML nor a runtime; image-backed render
targets exercise density changes through public Qt APIs.

`HistoryBrowser<Memory>` runs without a Qt application, socket or session.
It owns query, scope, row and inspection storage, and returns wire requests
for the caller to send. Those requests borrow its storage and must be encoded
before another search replaces it. Pages retain the runtime's insertion
boundary; stale replies and deletion confirmations cannot replace a newer
search. Failed allocation preserves the previous page while disabling its
submission authority. Inspection and selected-command reads have their own
failure states.

`HistoryModalGeometry` independently reproduces the original panel, filter,
list, inspector, bottom search and footer rectangles in physical pixels.
Opening details and replacing a result page preserve the input position;
narrow details replace the list instead of compressing both views. The Qt
adapter projects those rectangles once into logical coordinates. The original
geometry matches 12,480 frames on macOS and Fedora, including ASan/UBSan.
`HistoryFilters` and `HistorySearchBar` accept values and emit semantic signals;
their component tests need neither an application controller nor a runtime.
[History validation](measurements/history-modal-validation.json) retains native
scale checks, actual captures, initial fixture failures and remaining visual
and native-leak gaps.

`HistoryFilterGeometry` and `HistoryFilterChipGeometry` fit measured labels,
scope values and terminal-font key hints in fixed arrays without Qt or allocation.
`HistoryFiltersLayout` projects the rectangles into Qt coordinates, and the
standalone components retain delegates across selection changes. Their original
methods match 18,864 records on both systems. Six actual Cocoa/Metal scenes have
identical header pixels, including workspace/directory values, the failure ring
and narrow fitting. [Filter validation](measurements/history-filters.md) records
the scope, native scales, directory-update regression and remaining acceptance.

`BoundedEditor<Capacity>` and `FormFieldGeometry` provide fixed UTF-8 editing,
directional selection, grapheme movement and physical form geometry without Qt
or allocation. `NativeFormField` adapts Qt input and IME; `FormTextField` reuses
the cell renderer and works independently of the application controller.
The original snapshot path matches 106,511 editing transitions on both systems
and Linux sanitizers. Seven actual Cocoa/Metal search bands match all pixels,
including selection, scrolling, missing glyphs and provisional composition.
[Search-field validation](measurements/history-search.md) retains the exact
regions, original persistent-scroll crash and native scale checks.

The history controller now projects the raw editor text separately from its
parsed search query. Controller changes update the visible field; delivered
pages and filter changes preserve selection and provisional composition when
the text is unchanged. Overflow keeps the UTF-8 prefix that fits and reports
`prompt.history_query_bytes` through the existing session ledger. The reusable
`Utf16Prefix` measures the requested byte count without allocation before Qt
encodes the accepted prefix. [Query validation](measurements/history-query.md)
records the failed regressions, final native pixel regions and the intermittent
standalone Cocoa composition failure. Later [composition validation](measurements/form-composition.md)
separates reproduced focus loss from the historical unexplained commit variant.
The first Escape cancels provisional input before leaving history or its inspector.
`FormInputContext` projects Qt's surrounding text independently of the committed
editor selection. A compile-time-selected native event bridge handles Cocoa's
composition key interception; platform event decoding stays in `platform/macos`.
Complete physical IME lifecycle, full-window parity and comparative performance
remain acceptance gates.

`HistoryInspectionFacts` and `HistoryInspectionLines` format the selected
command, six facts and captured output as one borrowed line sequence without Qt
or allocation. The Qt inspector renders only the visible lines with the shared
cell and chrome text components. It reuses modal geometry and revision-guarded
actions; `FormButton` supplies the original button appearance without moving
focus away from the query. Terminal and inspector wheel input share the same
Qt event conversion and bounded fractional accumulator.
[Inspector validation](measurements/history-inspector.md) records original-source
comparisons, exact scoped images, platform checks and remaining input gates.

History metadata invalidation also follows the selected command's live pane and
canonical tab label. A bounded cache detects name and presence changes without
rebuilding result rows or changing their revision. The inspector retires an
unavailable action before its delegate is removed, including a held visit press.
[Live metadata validation](measurements/history-live.md) records runtime-backed
regressions, independent components, native scale checks and the remaining
continuation-glyph difference in the complete modal capture.

`HistoryScroll` routes wheel input across the complete delivered modal without
Qt or allocation. It validates the presented dialog generation and row revision,
uses the smallest delivered row for results and terminal cell height for
inspection, and retains fractional gestures through the existing bounded
accumulator. The Qt adapter records those bounds at frame preparation and adopts
them after presentation. Selection changes stop when paging admits a new request.
Per-event metadata distinguishes native pixel scrolling from ordinary wheel
estimates, including a device shared by trackpad and mouse events.
[Scroll validation](measurements/history-scroll.md) records the original-source
comparison, integration checks and native input captures.

`HistoryEmpty` and `HistoryEmptyGeometry` resolve first-search, failure and empty
result messages without Qt or allocation. They retain the original workspace
title limit, import hint, recovery button and physical text placement. The view
loads only for an empty page, and its recovery signal can be tested without an
application controller. Recovery preserves the query and its keyboard focus.
Both Qt forms of Shift+Tab cycle history authors.

`LoadingCue` retains the original 150 ms replacement-page delay. `HistoryLoading`
derives the 40-step, 24 ms loading band; the Qt adapter shares the existing window
clock and dims retained rows only while the cue is visible. Finishing a wait or
retiring its component parks the clock. Property observers can retire either
status component during notification. [State validation](measurements/history-states.md)
records the original-source comparison, native pairs and remaining platform gates.

`HistoryRowGeometry` fits the status, command, provider, directory and date
without Qt or allocation. Its six rectangles match 14,304 original-source
frames. `HistoryLabels` matches 64,092 original label records, including signed
time boundaries and timezone offsets. The platform wall clock supplies one
calendar sample per adopted page; the shared search parser also projects a
leading failure-only marker into the filter and grouping state.

`HistoryRow` accepts record, theme, typography and selection values and emits
selection and semantic card actions. Closed rows use the terminal cell grid, native chrome labels,
original fact admission and continuation marks. Double clicking preserves the
history panel instead of submitting its command. Day headings and clock/date
labels are projected with the page. [Row validation](measurements/history-rows.md)
records the original-source comparisons, standalone components, integration,
native scales and editor checks.

`WrappedLines` borrows complete command lines while retaining spaces, CRLF,
grapheme boundaries and replacement-cell widths. `HistoryCard` bounds its line
count and steady height by the list viewport. `HistoryMatchHighlight` sends
visible matching cells to a compile-time sink and carries query progress across
lines. The Qt row uses the complete selected command, clips inside its frame
and reveals the selection again after a height change. The unchanged original
methods match 19,738 records on macOS and Fedora, including Linux sanitizers.
[Card validation](measurements/history-card.md) records the regression,
native captures, visibility checks and remaining limits.

`HistoryPath`, `HistoryFacts`, `HistoryHintGeometry` and `HistoryMetaGeometry`
provide bounded compaction, streamed labels and original action fitting without
Qt or native windows. Their original-source probe matches 18,952 records on
both systems and Linux sanitizers. The Qt metadata and hint components work
independently, and native input checks cover card actions and platform keys.
[Metadata and paired-pixel validation](measurements/history-facts.md) retains
the regressions, source snapshots and actual GUI captures. One complete selected
card matches 269,760 RGBA pixels. Full-window pixels, expansion animation,
exact group placement, inspector facts and
comparative performance remain open.

`HistoryFooter` and `HistoryFooterGeometry` resolve bounded labels and fitting
without Qt or dynamic collections. The reusable Qt footer shares hint rendering
with selected cards and routes clicks through existing history operations.
[Footer validation](measurements/history-footer.md) records 14,888 original-source
matches on both systems and Linux sanitizers, 49-entry integration checks and
exact footer pixels in browse/inspect captures. Other visual states and
error-caption shaping remain open.

`HistoryPageStorage<Memory>` keeps UTF-8 previews bounded to 512 bytes and
complete long commands in a contiguous cache capped at 768 KiB. A selection
outside that cache requests its exact entry into a separate buffer capped at
64 KiB. Submission remains disabled until the complete matching reply arrives;
changing the search invalidates that ownership. Returning to the last loaded
detail reuses its bytes. The page storage can also run independently of the
browser.

`KeyRouter<Action, Event>` and `BindingMap<Action>` use bounded arrays and
templates. They require no window, Qt object, Lua VM or socket. The router
returns typed decisions for forwarding, replay, actions, pending input and
discarded input. Its 64 physical leases distinguish binding-owned keys from
forwarded keys across releases, repeats and configuration replacement.

`ConfigurationGeneration<Memory>` owns the Lua VM, local-module loader,
compiled bindings and callback references together. A replacement generation
is validated before adoption. Invalid configuration preserves the previous
generation. Callback contexts are immutable; callbacks have a 100,000
instruction budget and a 100 ms deadline. Only scroll actions repeat, at
most ten times per second while their pane remains eligible.

`ConfigurationSource` schedules a comparison of the main file and loaded local
modules once per second, using native file kind, size and nanosecond modification
times. `ConfigurationLoader` reads files and prepares an independent Lua VM
on a worker. Immutable requests carry dependency snapshots and revision tokens;
one active task and coalesced pending requests bound the work queue. Qt validates
the font and adopts a complete result on its event thread. Superseded results
cannot replace a newer selection or forced reload.
Unrelated directory changes preserve the generation and callback state.
Modules loaded later by callbacks are added to the same bounded dependency
set. Failed replacements keep the active generation and remember the failed
file stamps until another change or a forced reload. CLI reloads reevaluate
unchanged sources. The monitor and its tests need no application window,
QML engine or runtime connection.

Initial `open()` remains synchronous before window creation. A callback's
lazy `require` and dependency discovery remain synchronous on its calling
thread. Shutdown waits for the active worker and consumes its result before
the injected allocator can be destroyed. The worker does not borrow the
active generation or access GUI objects. The standalone monitor tests cover
pending work, event-loop progress, coalescing, late results, callback state,
dependency additions and shutdown. The
[paired reload experiment](measurements/configuration-reload.md) measures the
Qt-thread occupancy separately from end-to-end completion and process CPU.

`KeyEncoder` encodes semantic input into a fixed buffer without Qt or an
allocator. It preserves the original Kitty, cursor and legacy control-key
behavior. `KeyAdapter<Convention>` converts Qt events using a compile-time
Apple or standard convention. Both conventions can run in the standalone
adapter test without constructing an application or window. Native releases
retain their press's character and modifiers; synthetic input uses the same
semantic encoder directly.

Keyboard copy mode uses a Qt-independent navigation model and staged effects.
`CopyState` owns the cursor, selection, viewport and search position;
`CopyMode` keeps its bounded match buffer separately. Plans copy the navigation
state and borrow replacement search results until commit. The session sends
copy requests before committing their exit, restores the entry viewport,
rejects unrelated search replies and clears ownership on detachment.
The renderer projects the copy cursor and invalidates selection damage by row.
Physical copy keys keep the copy state's pane as their owner when focus
changes inside the same tab, including while a file opens in an editor.

Pointer selection uses the same model. `ClickTracker` resolves character,
word and line selection from explicit timestamps. `routeCopyPointer` returns
ownership decisions without Qt or a session. Gesture ownership survives a
resized or detached screen until its release, including failed copy requests.
`WheelAccumulator` retains fractional deltas, limits each event to 32 lines
and resets on gesture boundaries. A line scrolls three viewport rows or sends
one child mouse report. Keyboard, release, mouse and focus-report input have
separate effects on retained selection and viewport restoration.

`ChildMouseGesture` keeps one button's pane identity, attachment generation,
location, last sample and geometry without borrowing a pane. The window's
`PointerDispatcher` owns three independent slots, so buttons can retain
different panes. Qt still admits fresh presses through its hit testing;
transferring its exclusive grab preserves acquired application gestures.
Child reports use stable pane identities, while local selection and link
gestures use weak view references and their own held-button masks.

Captures survive pane focus changes. An attached pane with a hidden or
replaced view keeps its stored geometry; visible views update the projection.
Detachment invalidates the affected capture. Lost grab and window deactivation
finish captures, and late physical releases are consumed. Retained coordinates
clamp to the current grid. The SGR tracking policy and pixel projection run
without Qt or allocation. `TerminalSurface` supplies the shared geometry for
child mouse capture and link presentation. Complete pointer equivalence with
chrome, modal transitions and native input devices remains unverified.

`Session::navigateDirection` forwards the matching control key when the
reported foreground executable is `nvim`, using the pane's current keyboard
protocol. Other foreground processes use directional pane focus. Explicit
focus remains a separate action. `Session::scrollFocused` owns the shared
binding policy for mouse reports, alternate-screen arrows and history
scrolling without requiring a Qt application.

Link recognition runs without Qt, a socket or filesystem access. URI,
Markdown and local-path recognizers share bounded text ranges. `LinkGrid`
walks VT-confirmed soft wraps, skips wide-glyph padding and rejects links
truncated by the viewport. `CellLinks::resolve` gives OSC 8 metadata priority;
incomplete metadata cannot authorize a URI-shaped label as its destination.
`CellLinks::text` preserves the copy cursor's text-only extraction policy.

`LinkHit`, `LinkGesture`, `LinkHover`, `LinkPointerPolicy` and `LinkRegions`
also run without Qt. A click retains the target's complete identity and the
view revision until release. Intervening target, layout, attachment or
configuration changes cancel it even when the original state is restored.
Hover resolution caches the cell, screen revision, geometry and modifiers.
Alt removes the link target; guessed paths require the native link modifier.
Right click copies a displayed target and child mouse tracking owns ordinary
left clicks unless Shift overrides it.

The Qt adapter shares immutable hit snapshots allocated through the injected
allocator when their identity changes. Render synchronization borrows these
snapshots; the existing bounded frame queue publishes the captured hit and
preview coverage after presentation, rejecting obsolete attachment
generations. A hidden preview retains its delivered input coverage until its
replacement frame arrives. Underlines use transient scene nodes, preserving
the retained terminal text. `LinkPreview::layout` and the terminal scene can
be exercised independently of the application and runtime.

`ExternalLinkOpener<Host, Observer>` owns an asynchronous Qt process and a
last-pending-target queue. Host and observer calls use templates and concepts.
The platform adapter selects `/usr/bin/open` on macOS and `xdg-open` on Linux.
Each operation has a five-second deadline and independent 4096-byte stdout
and stderr limits. Shutdown cancels its process and queued targets.

`FilePath` decodes local file URIs and separates line/column positions from
paths found in prose. `PathExpansion` expands HOME and environment variables
through a template-constrained lookup, then resolves relative segments
lexically. Absolute file paths remain literal when opened. These components
require neither Qt nor filesystem access. The native environment lookup stays
in `platform`, caches raw byte values for the operation's lifetime and uses
[Qt's environment access](https://doc.qt.io/qt-6/qtenvironmentvariables.html#qgetenv)
to preserve Unix values without converting them through QString.

`EditorLaunch` borrows the executable and file and owns only its formatted
position argument. It reuses runtime editor identification and returns at
most three argv entries without shell interpretation. `EditorOpening` owns
one correlated request, including both strings, the runtime pane generation,
the client attachment generation and the source location. The session asks
the runtime to check the file and reuse an editor; an unavailable editor
creates a sibling pane. Matching successful replies focus the reused editor.
Changed identities and duplicate replies cannot launch or focus a pane.
A pane without a runtime generation launches directly, without a reuse or
file-existence check. Without a source, an absolute file opens in a new tab.

`client.editor` selects the executable, with the current configuration profile
taking precedence over the inherited value. An absent configured editor uses
the GUI process's `EDITOR`. Spaces belong to the executable path; additional
shell arguments are not parsed from this value.

`Session::consume(payload, handler)` accepts a borrowed callable constrained
by `ClientCommandHandler`. The session validates and completes routed
commands; the callable handles operations owned by the host UI. The Qt
adapter uses it for history dialogs and configuration reloads. Headless
callers can inject another implementation or use the default explicit
rejection. This path uses direct template calls without virtual dispatch or
an allocated callback wrapper.

Qt manages its own objects and scene graph allocations. They are outside the
injected allocator's accounting. CPU image storage has a shared budget across
panes; Qt texture allocations are not included in that budget.

The port reuses the C++ wire codec, bundled font loader, terminal face setup,
function-key fallback encoder, login shell and runtime discovery from `desktop-mode`.
It reuses the allocator, Lua VM, local module loader and configuration
validators from `runtime-cpp`. Theme presets and the Kitty placeholder table
are generated from the original sources at build time. No Zig GUI object code
is linked into this executable.

`Machines` retains the seventeen window slots and their admission generations,
owned profile fields and event-updated summaries without Qt or dynamic storage.
`MachinePicker` shares the bounded fuzzy ranker and preserves label-first
matching, slot-order ties and disabled machines. Its submission policy rejects
retired identities and keeps local toggles inert. The
[registry comparison](measurements/machine-registry.md) covers this independent
foundation. `qt::MachineClient` now owns each admitted session and connection;
the shared `Application` keeps fonts, input dispatch, native effects and scene
resources. Two framed socket fixtures verify presentation switching and origin
isolation, including colliding pane/frame identifiers and held keys. The
[window adapter report](measurements/machine-window.md) records the validation
and unsuppressed native leak gate. This was the checkpoint before saved profile admission was connected.
The [SSH transport report](measurements/machine-transport.md) adds a bounded
subprocess discovery/stdio bridge to the existing framing transport, with
controlled process coverage and unsuppressed ASan/UBSan acceptance. The
[saved-profile adapter](measurements/machine-admission.md) now admits enabled
SSH clients in production, reconciles stable IDs and scopes remote window
identities by destination. Actual SSH-host validation and the four machine
actions remain open.

## Build and run

Dependencies are CMake 3.24+, Ninja, Python 3, a C++23 compiler and Qt 6.7+
with Gui, GuiPrivate, Qml, Quick, QuickControls2, Network, Concurrent and ShaderTools. ShaderTools
compiles the portable curve shaders during the build. Qt Test is required when
`BUILD_TESTING=ON`. Lua and the fonts come from the repository. CMake downloads
the same pinned FreeType 2.13.2 archive as the Zig build, verifies its SHA-256
and compiles the source list from `build/freetype.zig`. Configuration parsing also
links the pinned libghostty-vt used by `runtime-cpp`, so configured agent icons
use the same Unicode grapheme-width rules. Once that library is installed,
the CMake/C++ build does not require a Zig compiler. For offline builds, CMake's
`FETCHCONTENT_SOURCE_DIR_TELAR_FREETYPE` can name an extracted copy of that
archive. The installed executable includes the FreeType and Ghostty licenses.
Linux also requires Fontconfig development headers and libraries. The native
font matchers are compiled directly from the existing Zig GUI's C/Objective-C
sources; the application and font-grid model contain no OS-specific calls.
QRhi texture uploads require the GuiPrivate development headers matching the
installed Qt version on both platforms. Fedora provides them in
`qt6-qtbase-private-devel`. On macOS, the shared optical text backend also uses
GuiPrivate, CoreText and CoreGraphics. Private Qt headers stay in the native
font and Qt graphics adapters.

Use an existing prefix from the runtime build or build the dependency with the
repository's Zig toolchain:

```sh
python3 services/runtime-cpp/tools/build_ghostty.py \
  --build-dir services/gui-cpp/out-dependencies/ghostty-build \
  --prefix services/gui-cpp/out-dependencies/ghostty
```

```sh
cmake -S services/gui-cpp -B services/gui-cpp/out -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DGHOSTTY_VT_ROOT="$PWD/services/gui-cpp/out-dependencies/ghostty" \
  -DCMAKE_PREFIX_PATH=/path/to/qt
cmake --build services/gui-cpp/out --parallel
services/gui-cpp/out/telar-gui --socket /path/to/runtime.sock
```

On Homebrew installations with separate Qt modules, the tested discovery
settings are:

```sh
cmake -S services/gui-cpp -B services/gui-cpp/out -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER="$(brew --prefix llvm)/bin/clang++" \
  -DGHOSTTY_VT_ROOT="$PWD/services/gui-cpp/out-dependencies/ghostty" \
  -DQt6_DIR="$(brew --prefix)/lib/cmake/Qt6" \
  -DQT_ADDITIONAL_PACKAGES_PREFIX_PATH="$(brew --prefix qtdeclarative)"
```

### Neovim and clangd

The local `.clangd` reads `out/compile_commands.json`, exported by CMake.
Configure and build the native target before opening it in Neovim so Qt's
generated headers and the generated theme and graphics tables are available.
Use a clangd version compatible with the configured C++ compiler and standard
library. On Homebrew, use the `clangd` from the same LLVM installation as
`clang++`. The clang-tidy profile used by clangd requires LLVM 23 or newer.
CMake also exports `out/clangd/config/compile_flags.txt` from `gui-config`'s
transitive include directories and definitions. Configuration headers use
these flags when opened directly, including Lua and the configured Ghostty
prefix, independently of which source files are already open in the editor.
Headers in the domain layers use `out/clangd/domain/compile_flags.txt`, generated
from the shared configuration and font dependencies. This prevents clangd from
inferring an unrelated platform-only command that omits protocol or shaping
includes. The generated flags follow the current CMake dependency paths on
both platforms.

Pure platform headers use the domain flags too. Qt headers and the Qt-backed
environment adapter use `out/clangd/qt/compile_commands.json`, copied from the
actual application command so framework, protocol and runtime include paths
remain available when opening a header directly. Normal native builds and
`gui-editor` refresh this database; unchanged content does not trigger a rewrite.
With `BUILD_TESTING` enabled, test headers use `out/clangd/tests/compile_commands.json`,
derived from the Qt Quick integration-test command. This includes Qt Test and
Quick headers without depending on which test source is already open in Neovim.

`.clangd-build.json` follows the other C++ services' Neovim build-on-save
integration. It refreshes the compilation database, generated headers and
native GUI library using the existing CMake cache and dependency overrides.
To run the same refresh manually from the repository root:

```sh
cmake -S services/gui-cpp -B services/gui-cpp/out
cmake --build services/gui-cpp/out --target gui-editor --parallel 2
```

The endpoint comes from `--socket`, then `TELAR_SOCKET`, then the shared
`telar server endpoint` discovery path. The connected runtime must speak the
repository's current wire schema. Closing the GUI leaves its runtime and
child processes running.

Configuration comes from `--config`, `TELAR_DEVELOPMENT_CONFIG` or
`$XDG_CONFIG_HOME/telar/config.lua` (`~/.config/telar/config.lua` by default).
File polling detects writes, removal, recovery and atomic replacements,
including changes to loaded local modules in nested directories.
An invalid reload retains the previous preferences. `--no-config`,
`--profile NAME` and `--theme NAME` are available. The supported configuration
subset is listed in the parity document.

`client.prefix`, `client.input.sequence_timeout_ms` and `client.keybindings`
use the original Lua API. A prefixed binding accepts up to four suffix keys;
a global binding accepts up to five keys. Configured sequences replace every
default with a conflicting prefix. Other defaults remain available. Duplicate
or ambiguous configured sequences reject the replacement generation.
The application prefix waits until another key or cancellation. Global
sequences use the configured timeout and replay their original input on a miss.

Bindings can return native actions or Lua callbacks. Expressions return
`telar.input.consume()`, `forward()`, `keys()` or `paste()`. `forward()` uses
the complete effective trigger, including an overridden prefix. Expressions
accept at most sixteen keys or 4096 paste bytes. Subsystems listed as missing
in the parity document still reject their actions, including when a callback
requests one of them. Limit reporting remains incomplete.

`telar.action.command_tab{command={...},label='...'}` opens a tab from a
configured binding or a callback result. Arguments remain separate argv entries;
execution uses the focused attached pane's runtime identity to inherit its
working directory. The confirmed tab receives focus, and an empty tab closes
automatically after the command exits. Closing an active tab selects its next neighbor, or its previous
neighbor at the end. Tab creation, rename, movement and closure share one pending
operation; a command reports a busy limit while another operation owns it.

Command rows use the shared packed registry with compile-time storage policies.
Runtime validation retains the original 80 KiB and 768-row limits. The GUI adds
the original 64 KiB and 256-row recent reserve, with generation and epoch checks.
Fixed rows survive recycling; callback references remain valid across subsequent
invocations until their recent region expires. A render refuses excess rows
without expiring commands already produced in that render. Actions carry typed
row references directly, without creating Lua registry references or allocating
an action-description entry. Core tests inject every allocation failure during
confirmed-tab adoption and verify that existing panes, tabs and focus survive.

`client.window_title` accepts up to 128 bytes of printable UTF-8. Profiles can
replace or clear it; an empty template restores the original GUI default,
`Telar`. `{workspace}`, `{tab}`, `{pane_title}` and `{hostname}` use the current
workspace, manual tab label or focused foreground process, focused OSC title,
and local host name. Unknown tokens remain literal. `WindowTitle` expands into
256 bytes, removes ASCII/C1 controls and discards an incomplete or invalid UTF-8
tail. It can run without Qt, an allocator, a session or a window. Its bounded
suffix operation is available independently; held-limit suffix delivery and
native saved machine-label presentation remains unverified.

Routed `sidebar_resize` requests validate and clamp semantic column widths,
preserving visibility and at least twenty workbench columns. The minimum
preference is 42 columns, including when a narrow host cannot display it.
Repeated widths preserve state without another layout-retention request.
The runtime-retained semantic width and the GUI's logical pixel width remain
separate, as in the original GUI; this command does not replace
`gui.sidebar.width` or the pointer's pixel preference.

`client.history` supports `show_agent_commands`, `enter` and `match`.
Defaults are human commands, paste on Enter and fuzzy matching. Shift+Enter
inverts the configured paste/run choice. Submission resolves the selected
entry's identity against the current results, rejects truncated captures,
and validates UTF-8 and terminal controls before sending input. Newlines
and tabs require the terminal's bracketed-paste mode. CLI-routed history
opening and forced configuration reloads use the runtime's command protocol.
Reloading an unchanged file still executes it; an invalid reload retains
the adopted preferences. Reload requests without a loaded configuration fail.

`--cwd PATH` sets the launch directory. Positional arguments select the
command for a newly opened pane; options following the command are passed
to that command. `--fresh` skips restoration of the window's saved layout.
Without an explicit command the shared login-shell resolver supplies the
interactive shell. `--smoke-ms N --screenshot PATH` provides a bounded native
window smoke run and returns failure if it cannot connect and display a pane.

## Tests

The twenty-three core test executables require neither Qt nor a running runtime:

```sh
cmake -S services/gui-cpp -B services/gui-cpp/out-core -G Ninja \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DGHOSTTY_VT_ROOT="$PWD/services/gui-cpp/out-dependencies/ghostty" \
  -DCMAKE_BUILD_TYPE=Debug -DTELAR_GUI_NATIVE=OFF
cmake --build services/gui-cpp/out-core --parallel
ctest --test-dir services/gui-cpp/out-core --output-on-failure
```

They exercise frame atomicity, fragmented transport, allocation ownership,
layout validation and resizing at the 64-pane capacity, byte-exact layout tokens
from the Zig encoder, routed history-coordinate
copy requests, attachment races, history result ordering and replay authority,
ASCII/C1 controls, malformed UTF-8 and history query byte boundaries,
image budgets and replacement, Kitty placeholders, configuration overlays,
peer authentication, window lease security and every valid Unicode scalar's
UTF-8 round trip. Font-grid tests cover fixed-point rounding, fractional leading
and invalid dimensions without FreeType or a font file.
Valid Braille and block geometry uses fixed-capacity
values without Qt or heap allocation. On supported toolchains,
`-DTELAR_GUI_SANITIZERS=ON` enables ASan and UBSan for C++ targets. The macOS
Objective-C and Objective-C++ backends are not instrumented by that option.
The vendored FreeType C target receives ASan; C++ wrappers receive both
sanitizers. On macOS the native compilers default to the configured Clang C++
compiler; `OBJC`/`OBJCXX` or the corresponding CMake compiler variables can
select them explicitly. CMake tests support for
`-fno-objc-msgsend-class-selector-stubs` and uses it when available for
compatibility with the system linker. The option is listed in the
[Clang command reference](https://clang.llvm.org/docs/ClangCommandLineReference.html).

To include the Qt integration test, configure the native build with
`-DTELAR_GUI_TEST_RUNTIME=/absolute/path/to/telar-runtime`, then run CTest.
The test starts and terminates its own runtime with an isolated socket,
history database and data directory. It verifies keyboard input and rendered
output, typed QML actions and named dialog fields, split resizing and closure,
tabs, image pixels and deletion, dialogs, history, workspace-list collapse
and restoration after destroying and rebuilding the window. It also sends
routed commands from a second client, exercises Enter/Shift+Enter, and checks
forced reload, invalid-reload retention and subsequent recovery. The history
scenario imports more than one page, navigates it through QML, inspects output,
copies and deletes a selected command, and changes its scope and author filters.
Another scenario exceeds the long-command cache and verifies that a selected
48 KiB command reaches the clipboard and inspector in full rather than using
its preview.

On Sway, a separate live-density check starts an isolated runtime and GUI,
changes one output through 100%, 125%, 200% and back, and reads the child's
actual PTY dimensions with `TIOCGWINSZ`:

```sh
python3 services/gui-cpp/tools/check_live_scale.py \
  --runtime /absolute/path/to/telar-runtime \
  --gui services/gui-cpp/out/telar-gui \
  --artifacts /tmp/telar-live-scale
```

Provide `SWAYSOCK` or `--sway-socket`, and select `--output` when multiple
outputs are active. Use a new artifacts directory. The check restores the
original output scale and terminates its own processes after success or
failure. Its fixture reuses the existing terminal experiment's atomic JSON
writer, including its SIGWINCH exclusion.
File-link coverage starts executable fixtures through the runtime, checks
complete argv entries after an editor configuration change, preserves copy
mode across the focus change, and reports a missing file from an identified
source pane.
Clipboard tests restore the previous MIME contents when they finish.

`TELAR_GUI_TEST_ARTIFACT_DIRECTORY=/path/to/artifacts` saves the history popup
and inspector during that scenario when running `gui-quick-test` directly.

The terminal-output scanner has a differential oracle against the repository's
original Zig implementation. It requires Python 3.10+ and the repository's Zig:

```sh
python3 services/gui-cpp/tools/check_plain_text.py --compiler clang++
```

The corpus contains 398,218 records: every pair of bytes after six scanner-state
prefixes, 5,000 deterministic random records with bounded destinations, and two
boundary cases. The C++ and Zig probes compare every returned byte; this is a
correctness check, not a comparative performance measurement.

Routed `config_show` with the `runtime` section reads the adopted configuration
generation. `RuntimeQuery` also accepts the shared typed `RuntimeValues` and a
caller-owned output span directly, without Qt, a Lua VM or a runtime connection.
It reports configured paths, graphics bounds, session flags, proxy/capture
settings, engine timeout and retained agent count. These are this GUI's
configured values; querying them does not reconfigure its running runtime.

The generation retains that snapshot through the injected allocator. Profile
overlays use the existing runtime reader. Queries do not execute Lua or read
configuration files; callback mutations and failed reloads preserve the adopted
values. A fresh valid generation replaces them. The bounded JSON writer retains
unsigned integer precision, null paths and the original short control escapes.
An oversized response fails with `WriteFailed` rather than returning partial
JSON or rejecting the valid configuration. Reply text borrows the source's
output buffer until the next query and must be sent or copied before then.

The `gui` and `input` sections also read the adopted generation. `GuiQuery`
accepts the typed preferences, an output span and the native titlebar default;
`InputQuery` accepts the typed input configuration and an output span. Both
work without Qt, Lua or a window. They preserve f32-to-f64 JSON promotion,
decimal formatting, the prefix's complete key representation and the count
of configured bindings before builtin defaults are merged.

The `binding` section queries one configured binding by its zero-based index,
in declaration order. It preserves prefix keys, semantic callback identities
and every original action payload, including command argv, notification values,
named definition indices and plugin hashes. Descriptions are captured during
configuration loading; querying a callback does not invoke it. Profile
replacement preserves the callback identity range established by the root.

`BindingQuery` consumes the typed input, action descriptions, shared command
registry and caller-owned output span. It has no Qt or Lua dependency. Command
views borrow the registry's packed storage, so queries do not copy complete
command buffers or allocate through the application allocator. Missing labels
derive from POSIX command basenames; non-UTF-8 command or label bytes retain
Zig's numeric-array JSON representation. Oversized replies fail with
`WriteFailed`, and missing configured indices fail with `BindingNotFound`.
Panel, pick and plugin descriptors remain query metadata; their
execution subsystems are unported.

The command pool also has a separate differential check against the original
Zig packed storage and lifecycle:

```sh
python3 services/gui-cpp/tools/check_command_tabs.py --compiler clang++
```

It compares 5,590 transitions, including 49 bounded refusals, complete argv and
label bytes, row identities, epochs, fixed/recent capacity, deduplication and
render admission. It complements the execution and ownership tests rather than
establishing comparative GUI performance.

The `theme` section preserves the complete configured base, light and dark
values. `ThemeValues` owns sixteen chrome roles, the terminal palette and
fifteen optional syntax styles. `ThemeReader` applies root/profile overlays;
`ThemeSelection` resolves appearance and CLI precedence without Qt or allocation.
The generated presets retain indexed and default colors as well as syntax
preferences from Zig. `projectTheme` separately derives renderer colors, so a
chrome text override does not change terminal ink. Explicit panel colors remain
opaque when the window background is translucent.

The Qt adapter observes [QStyleHints color scheme changes](https://doc.qt.io/qt-6/qstylehints.html#colorScheme-prop).
Appearance changes update the active theme without reloading Lua, replacing the
keymap, resetting a prefix sequence or restoring configured sidebar geometry.
A CLI theme lock takes precedence, and invalid reloads retain the adopted theme
and lock. Theme queries return configuration values independently of the active
appearance or CLI lock. A complete base/light/dark reply can exceed the original
4096-byte command limit; this fails with `WriteFailed` and leaves the snapshot
valid. Syntax preferences are retained for queries and standalone consumers;
comprehensive styled syntax rendering remains unported.

The `client` section is also the default when no section is named. Its
`ClientQuery` serializer combines the adopted sound, notification-delivery and
history policies with a supplied `ClientViewState`. The session supplies live
visibility, semantic sidebar columns, workspace-list collapse, pane gaps and
the unexpanded window-title template. Semantic columns remain independent of
Qt's logical pixel width. The adapter retains the requested source/profile
text and reads the adopted generation identifier without allocating metadata
on each query. Failed and unchanged reloads preserve that identifier; a valid
replacement advances it, including after clearing and reopening configuration.
The pure serializer also works without Qt, Lua, a window or a runtime.

All six query sections are routed. Unknown names fail with
`UnknownConfigurationSection`; a missing generation preserves the original
error priority. A negative index fails with `InvalidIndex` for other sections;
the `client` section ignores it, as the original does. Source/profile metadata
preserves null versus present empty bytes and Zig's invalid-UTF-8 representation.
The retired notification delivery value `terminal` retains the inherited
policy. Sound and system-notification execution remain unported; reporting
their configured policies does not implement those effects.
The shared `SnapshotReader` validates root values and every profile before
adoption, including unselected runtime, client, GUI, theme and plugin fields.
Validating an unselected profile does not adopt its values. Failed validation
retains the previous GUI, input and runtime snapshots.

```sh
python3 services/gui-cpp/tools/check_runtime_query.py --compiler clang++
python3 services/gui-cpp/tools/check_preferences_query.py --compiler clang++
python3 services/gui-cpp/tools/check_theme_query.py --compiler clang++
python3 services/gui-cpp/tools/check_binding_query.py --compiler clang++
python3 services/gui-cpp/tools/check_client_query.py --compiler clang++
```

This comparison compiles the runtime-section body extracted from the original
`config_queries.zig`. It matches 4,126 synthetic typed snapshots byte-for-byte,
including 1,633 bounded failures. It covers all eighteen fields, null paths,
Unicode and control escapes, unsigned limits, host arrays and response capacity.
It tests serialization; it does not prove complete Lua configuration parsing
or behavior of the other query sections. Headless tests also check retained
profile values, callback mutation, allocation failure, the full custom-agent
identifier range, Unicode icon validation and cleanup.

The GUI/input comparison uses the extracted original section bodies and the
original Zig GUI and key types. It matches 5,441 typed records byte-for-byte,
including 650 bounded failures. It covers every named prefix key and modifier
combination, one- through four-byte characters, NUL padding, platform defaults,
explicit titlebars, f32 promotion, tiny opacity values, escaped font names and
exact response capacities. It generates its binding header without configuring
CMake or loading Qt. These typed records do not prove complete Lua parsing.

The theme comparison compiles the original preset implementation, theme/key
color types, extracted query body, appearance resolver and syntax-style resolver.
It matches 2,318
typed records byte-for-byte, including 929 bounded failures. It also compares
all 16,777,216 three-byte UTF-8 decisions with Zig: RGB storage becomes a string
when valid UTF-8 and numeric elements otherwise. The throwing validator retains
its existing error names. All fifteen computed syntax roles also match, including
palette-derived defaults and explicit styles. These records cover typed serialization and theme
resolution, not complete Lua parsing or physical OS appearance delivery.

The binding comparison compiles the original action/key types, command pool
and extracted binding/action serializers. It matches 2,589 typed records
byte-for-byte, including 227 bounded failures. The cases include every action
shape, configured order, callback identifiers, all key modifiers, POSIX path
labels, invalid UTF-8 argv/labels and exact response capacities. The C++ probe
builds without Qt, Lua or CMake. Configuration parsing is covered separately
by the standalone and Qt integration tests.

The client comparison uses the original query body, window-title accessor,
sound policy and notification-delivery types. It matches 2,799 typed records
byte-for-byte on macOS and Linux, including 335 bounded failures. The corpus covers all
policy flag combinations, nullable/byte metadata, 64-bit generation identifiers,
semantic widths, live view fields and exact response capacity. These records
cover serialization. Separate monitor and routed tests cover adoption,
rejection, retained identifiers, relative source paths, profile selection and
window-state changes.

Title expansion and semantic sidebar clamping have an independent oracle:

```sh
python3 services/gui-cpp/tools/check_presentation.py --compiler clang++
```

It compares 155,464 byte-exact records with the original title module and
the clamping functions extracted from `src/model/layout/sidebar.zig`. The
corpus covers every two-byte title fragment, all token names, literal braces,
Unicode truncation, suffix bounds, random token bytes, narrow/wide hosts and
invalid command widths. Session tests cover focus and metadata changes, owned
title results, retained widths, repeated requests and rejection rollback.
The runtime integration test checks OSC-driven title delivery, configuration
adoption/recovery and routed sidebar completions.

The key router has a second standalone oracle:

```sh
python3 services/gui-cpp/tools/check_key_router.py --compiler clang++
```

It compares 29,152 transitions against `lib/keyinput/GenericRouter.zig`,
including every pair of fixture keys across press/repeat/release and capture
states, complete five-key bindings, Unicode, lease saturation, deadline
overflow and deterministic random operations. It compares action/replay
contents, prefix state, deadlines, repeat eligibility and physical ownership
queries. It uses the original router, not a copied reference algorithm, and
does not measure latency or throughput.

The semantic key encoder also has an oracle against the original Zig code:

```sh
python3 services/gui-cpp/tools/check_key_encoder.py --compiler clang++
```

It compares 448,936 records across every Kitty flag combination, modifier,
phase and cursor mode, plus modifyOtherKeys, Unicode and control boundaries,
alternate codepoint metadata, associated text and invalid shifted scalars.
Returned bytes and rejected inputs must match. This verifies the semantic
encoder; it does not establish every native layout, input method or function
key's equivalence, or comparative performance.

Copy navigation has a standalone oracle against the original model:

```sh
python3 services/gui-cpp/tools/check_copy_mode.py --compiler clang++
```

It compares 32,241 transitions with `src/model/input/copy_mode.zig` and
`State.zig`: ASCII and control input, named keys, Vim motions, word/paragraph
boundaries, CJK width, selection, search navigation, pointer primitives and
frame reconciliation. Its fixture uses a ten-column, four-row viewport.
The complete projected state and effects must match. This does not establish
all GUI pointer gestures, focus transitions or input-method behavior.

Link recognition has two differential tools:

```sh
python3 services/gui-cpp/tools/check_links.py --compiler clang++
python3 services/gui-cpp/tools/check_cell_links.py --compiler clang++
```

The first compares 198,338 records against `lib/urlscan`: complete URI
classification, punctuation, Markdown, local paths, line/column suffixes,
UTF-8, length boundaries and deterministic random input. The second compares
44,798 cell records, including complete destination bytes and absolute cell
intervals, against the original `cells.matchGrid` and `LinkGrid` functions.
It extracts private functions at run time and changes only the grid module's
position-type import. Cases cover wrap flags, wide cells, padding, viewport
boundaries and bounded traversal. OSC 8 precedence and incomplete metadata
are covered separately by the core link test.

Pointer link gestures have an independent oracle:

```sh
python3 services/gui-cpp/tools/check_link_gestures.py --compiler clang++
```

It compiles the original private `WindowModel.LinkGesture` and imports
`LinkHit.eql` directly. The 108,875 transitions compare active ownership,
complete returned identities and destination bytes. They cover each hit
field, every model-version field, absent targets, cancellation, restored
state, repeated release and deterministic random sequences. This verifies
the value model rather than Qt event delivery or GPU presentation.

File resolution and editor arguments have another differential tool:

```sh
python3 services/gui-cpp/tools/check_file_links.py --compiler clang++
```

It compares 47,275 records with the original `FilePath`, `Launch` and
`path_expansion.expand` functions, including failure names. Cases cover every
byte in representative file URI positions, percent decoding, local/remote
hosts, path bounds, fragments, supported editor conventions, executable
basenames, full-width coordinates, variable expansion and lexical segments.
The session's separate editor test injects recording transports and checks
reused-pane focus, fallback splits, busy/retry behavior, duplicate replies,
transport failure, pane identity changes and the 64-pane capacity. A pending
attachment confirmation cannot replace the identity of an already attached
view and invalidate its editor request.

The standalone Qt link-opener test needs a core event loop, without a window,
QML engine or application model. It checks queue replacement, process errors,
launch failure, timeout, output limits, recovery, literal arguments and
shutdown. A separate native build can select
`-DTELAR_GUI_LINK_HOST_HEADER=/absolute/path/to/host.hpp`; the header defines
`TELAR_GUI_LINK_HOST` to a policy exposing `start(QProcess&, const LinkTarget&)`
and `timeout`. Use the same compiler and Qt discovery settings as the native
build. `tests/recording_link_host.hpp` supplies a recording policy for that
build and enables terminal/routed opening and pointer-gesture integration
cases without launching a browser.
It records complete targets through a real process instead of opening a
browser. Keep this build separate from the normal `out` directory.

Pointer ownership, click timing and wheel quantization have another oracle:

```sh
python3 services/gui-cpp/tools/check_pointer.py --compiler clang++
```

It compares 22,440 records against the original `ClickTracker`,
`copy_mode_pointer.route` and `GuiAdapter.dispatchScroll` functions. The probes
replace widget interception and external effects with typed recording stubs.
Coverage includes retained gestures, missing panes, keyboard copy ownership,
clock boundaries, fractional deltas, scroll phases and deterministic random
sequences. This does not establish every widget gesture or native event path.

Retained child mouse coordinates and SGR bytes have a separate oracle:

```sh
python3 services/gui-cpp/tools/check_child_mouse.py --compiler clang++
```

It compares 81,680 records against the original retained coordinate clamping,
`pane_mouse_inputs.encodeReport` and `keyinput.tracked`. Coverage includes
tracking modes, modifiers, cells and pixels, scale, clipped and empty grids,
and exterior positions. Geometry fixtures replace application admission;
standalone tests cover capture identity and hidden geometry. Native tests
compare complete raw-PTY streams for simultaneous buttons, cancellation,
late releases, retention across pane focus changes and hidden views. Two-PTY
cases verify independently retained panes and cancellation across panes.
This does not establish complete chrome or native event equivalence.

For a Zig runtime executable, set its server arguments when running CTest:

```sh
TELAR_GUI_TEST_RUNTIME_ARGUMENTS='server --no-config --fresh' \
  ctest --test-dir services/gui-cpp/out --output-on-failure
```

CTest uses `QT_QPA_PLATFORM=offscreen` and `QT_QUICK_BACKEND=software` for that
test. Running `gui-quick-test` directly allows testing another Qt backend.
These checks verify selected flows; they do not establish complete GUI parity
or comparative latency, frame throughput or GPU completion time.

## Static analysis

```sh
cmake --build services/gui-cpp/out --target gui-lint
```

The profile requires clang-tidy 23 or newer, including its
[`IgnoreMacros` function-size option](https://clang.llvm.org/extra/clang-tidy/checks/readability/function-size.html).
Use clang-tidy and run-clang-tidy from the compiler's LLVM installation.
The target verifies `.clang-tidy`, builds the required generated headers, and
analyzes the service's sources and tests with warnings treated as errors. It
writes the diagnostic and suggested-fix report to `out/clang-tidy.yaml`.
`TELAR_GUI_LINT_JOBS` controls parallel analyzer processes. Clangd uses the
same configuration; tests have no separate diagnostic exemption.

The profile enables `*`, including new checks supplied by the installed LLVM.
With LLVM 23.1.2 it enables 500 of 602 checks. The exclusions cover rules for
other projects and hardware targets, trailing return types, replacing
`#pragma once`, banning reference members, and the three rules that prohibit
ordinary indexing or iterator arithmetic even after explicit bounds checks.
The checked frame decoder, fixed layout capacities, allocator budgets and
sanitizer tests remain part of the validation required for those operations.

Names, function length, parameter count, nesting, cognitive complexity and
magic numbers have explicit checks. Classes with private state must keep that
state private; public value records are allowed. Include cleanup retains the
public POSIX headers and ignores OS implementation headers so a check on macOS
does not introduce private Darwin includes into Linux sources. This uses
clang-tidy's documented [header filtering option](https://clang.llvm.org/extra/clang-tidy/checks/misc/include-cleaner.html).

The LLVM 23.1.2 run completed with zero diagnostics across the service's
63 translation units, including tests, the reload probe, the Objective-C++
window adapter and the shared optical text and terminal-font implementations.
The Fedora validation compiler is LLVM 21.1.8; that installation can build
and test the service but cannot run this lint profile.

The `gui-scene-test` target renders terminal cells directly from a
`TerminalPresentation`, without an `Application`, runtime, socket or QML
engine. Its image checks cover opaque and hollow cursors, configured cursor
text color, concealed text, original underline variants, selection cache invalidation
and transient hovered-link underlines. The same target checks preview wrapping,
ellipsis, pane bounds and invalid geometry without instantiating the GUI.

`FontSource<Memory>` owns font bytes through the injected allocator.
`fonts::Face` borrows those bytes, applies native collection selection and
variation coordinates, and obtains metrics from the pinned FreeType build.
`FontGrid` retains the original single-precision arithmetic: integer physical
cell dimensions, maximum advance, line spacing and half-pixel baselines.
Qt face setup uses that geometry instead of deriving another cell from Qt's
ascent and descent. Terminal resize reports use the same physical dimensions.

`FontCache<Memory>` retains one source and face across panes, with eight bounded
scale entries. It stages replacements before adoption, preserving the previous
source on failure. Optical weight preferences do not invalidate geometry.
Returned fonts own their Qt values, so cache eviction cannot invalidate a
presented row. Source storage and generation ownership use the caller's
allocator; internal Qt and FreeType allocations remain outside those counters.
Initial source loading and font validation still run on the Qt thread.

The standalone `gui-font-resolver-test` requires a Qt application but no window,
QML engine or runtime. It covers baseline and fractional scale, allocation
ownership, cache eviction and rollback, bundled-name matching, collection
selection and variable metrics. The checked-in
[font fixtures](tests/fixtures/README.md) contain distinct collection faces and
MVAR/HVAR changes; they do not depend on installed system fonts.
`FontResolver::resolve(face, configuration, scale)` also accepts an independently
loaded face for tests and experiments.

```sh
python3 services/gui-cpp/tools/check_font_grid.py --compiler clang++
```

This oracle compares 240,073 records byte-for-byte with the original
`FontSize.zig` functions and the metric arithmetic extracted from
`Renderer.measure`. It supplies synthetic FreeType size records and covers
signed 26.6 rounding, fractional DPI, cell spacing, baseline leading and rejected
bounds. It proves that arithmetic for those inputs; it does not prove complete
native face selection, localized family aliases, shaping or fallback parity.

`TextScene` shares the desktop client's concrete `OpticalText` backend when
`gui.font.thicken` is enabled on macOS. Rows, block cursor text and preedit use
the configured `thicken_strength`. Linux keeps native Qt text, matching the
original host policy. CoreText and Qt private font access remain in
`desktop-mode/native-backends/macos`; the application and terminal model do
not depend on those APIs. The backend has no virtual dispatch. Retained row
textures own their pixels independently of its reusable raster buffers.

The macOS-only `gui-optical-text-test` runs without a window, QML engine or
runtime. It compiles the original native glyph rasterizer and compares 360
complete images at matching physical origins: three bundled-font glyphs,
five sizes, two scales, three strengths and all four synthetic styles.
The comparison found and fixed differing bold clipping and italic ink bounds
in the shared backend. Separate tests compare translucent source-over with
Qt's compositor, preserve retained snapshots and reject invalid dimensions.
Scene tests cover configuration replacement, cursor/preedit smoothing and
procedural glyph invariance; routed configuration reloads also enable smoothing.
This does not prove complete glyph shaping, variable-font or fallback parity.

Bare Braille, block and straight box elements use cell-aligned rectangles
rather than font glyphs. The same geometry paints terminal rows and block cursor
ink, including
configured cell spacing and device scale. Shades blend at quarter, half and
three-quarter coverage. Combining sequences retain font shaping. Underlines
use scene rectangles for all supported styles so they also appear with Qt 6.10.
Image regressions cover bold/italic invariance, blank Braille, shade/faint
composition, selection, inverse colors, concealment, cursor repaint and
decoration order. The box edge table is generated from the original Zig
mapping. Straight intersections use disjoint rectangles so faint strokes blend
once. `gui-glyphs` contains the Qt-independent curve rasterizer; its translation
unit disables floating-point contraction to preserve the reference mask bytes.

Rounded corners and diagonals use the original bounded alpha-mask algorithm.
`CurveCache<Payload>` admits at most 56 geometry/shape identities and remembers
failed admissions. It can run with a test payload without Qt or allocation.
The Qt adapter reserves seven fallback slots for masks of 16 by 32 pixels and limits
exact rasterization to 256 by 256. A portable scene graph material applies
foreground color and opacity while sharing the alpha texture. The software
backend creates an owned colorized texture from the cached mask. Retained
native nodes keep their masks alive across font-generation cache resets.

The active FreeType face's units-per-em and underline thickness determine box
stroke thickness before rounding to physical pixels, including applied MVAR
changes. Standalone presentations can omit this metadata and use `BoxFont`'s
Qt design-table fallback. Underline decorations retain their physical cell-bottom
anchor independently of the font baseline. Image tests cover all drawing backends above,
cursor tint, faint intersections, oversized-cell fallback and repeated resize
with retained cursors. Scene captures wait for a backing surface large enough
to contain the cell before cropping it, independently of the initial size
selected by the compositor. Boundary tests distinguish the exact mask at
256 physical pixels from the reserved mask at 257, and retain a separate
large-cell case at 512 logical pixels.

```sh
python3 services/gui-cpp/tools/check_cell_glyphs.py --compiler clang++
```

This standalone differential check compiles the original `lib/cellglyphs`
parsers, Braille, block and straight box painters against a recording graphics
sink, and compares the original curve rasterizer's alpha bytes.
It compares 1,209,552 byte-exact records, including every Unicode scalar's
classification, malformed sequences, tiny and fractional cells, odd extents,
invalid bounds and stroke thickness, all Braille masks, every block and box
element, all seven curves, and raster padding and storage guards. It does not
compare GPU rendering or the complete native font-metric pipeline. The adapted glyph algorithms retain their
[MIT notice](terminal/glyphs/LICENSE), installed with the native executable.
