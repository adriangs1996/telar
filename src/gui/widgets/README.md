# Zig GUI composition

The GUI builds concrete Zig widgets during synchronous preparation of a client
`Projection`. Each widget draws through `Canvas`. Metal and Vulkan consume only
the sealed quad frame, glyph atlas and sprite page; adding a widget does not add
a native drawing callback or a GPU command type.

`Scene.prepare` starts the frame resources, then calls `Composition.render` with
the borrowed projection. That method returns the complete `frame_widget.List`:
terminal leaves, thread views, a hovered link, top bar, status bar, sidebar,
pane decorations, chrome focus, notifications and the selected modal. It emits
no quads. `Scene` draws the list once through `draw(canvas)` and seals the frame
and its control registries only after drawing and registration succeed.

```zig
var composition: Composition = .{
    .chrome = chrome,
    .overlays = overlays,
    .canvas = &canvas,
};
const widgets = try composition.render(&projection);
try widgets.draw(&canvas);
```

`Composition` owns the context borrowed by chrome widgets. Keep it and the
projection at stable addresses until drawing returns; returning the list does
not extend either lifetime. The list holds at most 73 widgets, derived from the
64-pane limit, one link, four chrome sections, one focus indicator, two notices
and one modal. A frame can contain both terminal and thread leaves. Its commit
captures the generations and damage of the panes actually composed.

`frame_widget.zig` declares the frame's tagged union. Add a variant and select it
in `Composition.render` to introduce a new frame section. Containers may build
their own concrete widget lists. `Surface`, `Text` and `Sprite` are reusable
leaves. All GUI widgets and their drawing support live under `gui/widgets`;
modal and notification widgets live in its `overlays` subdirectory. `Canvas`
belongs here too. Every drawable component implements `draw(self, canvas)`;
its geometry and semantic inputs are fields on the widget value. A container
draws its children through that same method.

`Chrome` and `overlays/Overlays` own retained interaction state and compose
widget values. They have no drawing entrypoint. `SidebarState` retains scroll
and snapshot ordering; `Sidebar.draw` borrows it while drawing the actual
sidebar. Tests use the same compose, draw and seal steps as the scene.

`Sidebar` composes the project list above the agent cards. `SidebarRegions`
resolves both viewports once per preparation, and the delivered hit map owns
scroll targeting. `SidebarState` retains separate `PixelScroll` values;
`WorkspaceList` clips project rows and reveals the active runtime identity.
`TopBar` preserves `TabStrip` geometry and shows workspace controls only when
the project list cannot be shown. Unlisted contexts keep their label there.
Tabs are not a separate frame section. `StatusBar` owns configured bottom
widgets and mode hints, with space reserved for TLS in every mode.

```mermaid
flowchart LR
    OS[Operating system] --> Host[Native input adapter]
    Host --> Queue[Owned input queue]
    Queue --> Dispatch[Zig widget dispatcher]
    Dispatch --> Commands[Shared application commands]
    Commands --> Model[Client model]
    Model --> Projection
    Projection --> Composition[Composition.render]
    Clock[Animation deadlines] --> Composition
    Composition --> List[Frame widget list]
    List --> Draw[Each widget.draw]
    Draw --> Canvas
    Canvas --> Frame[Quads and resource references]
    Frame --> GPU[Metal or Vulkan]
    GPU --> Completion[Presentation completion]
    Completion --> Registry[Delivered widget targets]
    Registry --> Dispatch
```

## Layout and drawing

The new-context form uses `overlays/WorkspaceFormLayout` and `DialogSurface`.
Its width, fields and folder rows follow chrome pixel metrics. The fields keep
their position while directory results arrive; at most four rows are visible,
with wheel/trackpad and arrow-key navigation. Small windows keep the active
editor and the form actions. Other modals still use their existing layouts.

`TextField.form_control` adds padding, rounded chrome and a thin caret. The
delivered editor geometry describes the inset text area at its own font size,
so pointer selection and native IME queries use the same coordinates. Context
buttons activate on release inside their delivered bounds. Folder targets carry
the prompt generation and listing revision; a stale click cannot accept a newer
result. The shared controllers continue to own completion and submission.
These controls use bounded frame storage and require no runtime UI state.

`layout/Layout.zig` resolves caller-owned `Item` arrays in device pixels. A child
uses fixed, measured-content or fill sizes, with minimum and maximum bounds.
Containers provide rows, columns, overlays, padding, gaps and alignment. Nest a
container by resolving another array inside its parent's assigned rectangle.
Chrome logical dimensions are converted through `ChromeMetrics.px` first.

`TerminalPane.draw` uses `Canvas.terminal` to paint canonical cells and the cursor
through the existing retained cell cache. Terminal shaping, selection colors and
cursor ordering stay in that specialized painter. Selecting terminal leaves is
the composition's job; the GUI no longer calls `TerminalRenderer.prepare` to
paint them before its widget list.

```zig
var rows = [_]LayoutItem{
    .{ .height = .{ .fixed = 24 } },
    .{},
};
try (Layout{
    .area = bounds,
    .direction = .column,
    .padding = .{ .left = 8, .right = 8 },
    .gap = 6,
}).resolve(&rows);

const WidgetList = GenericWidgetList(Widget, 16);
var widgets: WidgetList = .{};
try widgets.append(.{ .surface = .{
    .bounds = rows[0].bounds,
    .fill = .{ .color = palette.surface0, .radius = 4 },
} });
try widgets.draw(canvas);
```

`Widget` is the composition's tagged union; its `draw` dispatches to each
variant's `draw(canvas)`. The list owns the struct values, not copies of their
borrowed strings or pointers. Measure labels through `Canvas.measure` and supply
the result as the item's intrinsic size. A container owns clipping for both its
drawing and its hit regions. The list itself does not clip or scroll. Minimums
may overflow a small container; fixed/content items do not shrink implicitly.
Fill items receive equal shares above their minimums, capped by their maximums;
remaining excess space participates in alignment.

## Input and host services

`input/event.zig` defines committed text, paste, key phases, pointer gestures,
precise two-axis scroll, focus, IME composition, clipboard completions and
accessibility actions. Only `native/decode_input.zig` interprets numeric C ABI
tags. `NativeInput` copies borrowed payloads into bounded storage before native
callbacks return. The window thread drains them through `GuiClient.widgetInput`
before the terminal router. Terminal input keeps its physical-key and pane
ownership rules.

`Canvas.widgets` exposes the client's interaction state during drawing. Register
a `Target` with the rectangle actually painted, an owned semantic action, a
label, role and focus policy. `Dispatcher` retains the last successfully delivered
registry. It chooses focus, hover and per-button capture from that registry;
physical key leases prevent repeats and releases from changing owner. A modal
restricts new input to its layer. Tab traversal applies while a widget owns focus
or a modal is active, unless the target disables `traverse_tab`. `TextField`
disables it so shared handlers retain completion and form navigation. Terminal
Tab retains its existing behavior.

For targets without an explicit ID, the dispatcher reuses identity across
delivered frames by matching namespace, action and generation. Give controls with
the same action distinct namespaces. A changed generation or disappearance
retires the previous identity.

The permanent chrome registers its existing semantic actions. `TextField` paints
the prompt's committed selection and the client's provisional IME composition.
Editing becomes commands to the shared prompt handlers. Widget lists remain
transient Zig values; the dispatcher stores identifiers and copied actions, never
pointers to those values. A new application action is handled in Zig in
`widgets/interaction/routing.zig`.

The integrated editable state currently comes from `Prompt` through `FieldView`
and the shared prompt commands. An editor backed by another model needs its
state and commands connected in Zig; native adapters consume the same text
context contract.

A text widget supplies current UTF-8 surrounding text, selection byte offsets and
caret geometry. `widgetTextContext` exposes that state through a synchronous
snapshot. AppKit implements `NSTextInputClient`; Wayland implements
`text-input-v3` when the compositor advertises it. Platform adapters translate
native ranges and report provisional text, commits and cancellation. Zig owns
the selection and committed edits. Target ID plus generation rejects events for
retired editors. XKB compose remains the Linux fallback.

Use `requestClipboardRead(id, generation)` and `requestClipboardWrite(bytes)` for
asynchronous UTF-8 clipboard operations. `host/Services` owns requests and matches
their completions. A read cannot paste into a newly focused widget. Terminal paste
shortcuts also originate in Zig and capture the terminal attachment before the
read; delivery then follows the existing bounded pane paste path. Opening links
continues through the shared `LinkOpener` port. A cut uses an owned write request and deletes its
selection only after success while the captured editor revision still matches.

The delivered registry also publishes an accessibility tree with roles, labels,
values, focus, selection and supported actions for registered targets. It does
not expose the terminal's complete text contents. macOS exposes it through
`NSAccessibility`; Linux exposes it through ATK/AT-SPI. Native accessibility
actions return to the same Zig event queue. Partial text replacements include an
expected text revision, so delayed accessibility operations cannot overwrite
intervening edits. New widget semantics require no
Metal, Vulkan or platform-specific control implementation.

See [native input](../../../docs/flows/native-input.md) for limits, ownership and
host validation commands.

## Command history

`HistoryModal` uses a pixel layout, `DialogSurface`, a native search field and
rounded result rows. Commands and captured output retain their terminal font;
headings, scope and secondary metadata use the chrome typography. The layout
stays fixed while queries replace a page and adapts to the viewport and font
metrics. A wide inspector shares the dialog with the list; a narrow one uses
the available result area.

A row click selects without submitting. Rows and the primary action carry the
delivered history revision, so a replaced or pending page cannot run an unseen
command. Scope, inspection and submission use the shared history controllers.
The search field retains keyboard and IME focus. The TUI keeps its own layout.

The inspector's wrapped line count uses the same native layout as painting.
Its metrics travel with `HitState`, so failed presentations preserve the
visible geometry's scroll bound.

## Animation and invalidation

Child progress uses `PaneProgress` capsules in pane headers and a compact ring
in the active tab for a single pane. Fullscreen keeps the indicator beside the
pane selector. Percentages ease between reports over 240 ms; unknown progress
uses a rotating arc sampled from the presentation clock at 60 Hz. Pause and
error have distinct marks and stop animation. Removing progress clears the
indicator immediately, since removal can also mean interruption.

`Chrome.progress` retains bounded `ProgressMotions` by pane ID and attachment
generation. Only painted indicators renew their entries and deadlines; hidden,
removed and reattached panes cannot inherit a previous animation. `ProgressRing`
uses at most 66 rounded quads with a precomputed circle, without font shaping,
texture uploads or frame-time allocation. The frame budget reserves space for
one capsule per visible pane. The runtime and TUI keep their progress protocol.

History opens with a 220 ms cubic ease-out, fading in while moving up twelve
logical pixels. `Overlays` retains one `ModalMotion` keyed by prompt generation;
edits, query results and toggling details do not restart it. Painting and input
registration use the same shifted rectangles. Closing or finishing the entrance
leaves no animation deadline.

During scene preparation, `Canvas.animation` exposes a `FrameClock` with one
monotonic timestamp and one earliest requested deadline. A sprite can choose
`clock.step(interval_ns) % count`; a transition can use `clock.sample(transition)`.
`Transition.retarget` starts from the current value to avoid a discontinuity.
Transition state belongs to the client or widget owner, outside the transient
list. Attention rings demonstrate attachment-scoped ownership and retirement.

Each preparation resets the deadline requests and only visible widgets renew
them. Finished transitions request nothing. The GUI uses the host animation
clock instead of the model's TUI animation timer. The driver merges widget and
cursor deadlines, parks widget timers while a presentation is in flight or a
requested draw awaits the compositor, and resumes when preparation begins.
Late frames sample current time rather than
replaying intermediate states.

Local interaction advances the chrome or widget revision. Runtime/model revisions
continue through `LifecycleState`. Painting creates a complete frame; the GPU
still clears and draws the whole target. Cell meshes and glyph shaping are
cached, but this layer does not implement retained widget meshes, render-target
layers or partial GPU damage.

## Ownership, bounds and delivery

- The client owns layout, interaction and animation state. The runtime owns
  terminal contents and agent truth. Native callbacks only admit events; the
  window thread mutates GUI state.
- Widget lists have compile-time capacities and reject overflow. Layout uses
  caller-owned storage and linear passes without allocation. Measurements and
  lengths are validated before publishing any child bounds.
- Each registry holds at most 256 targets, including 16 editor geometries, with
  labels stored in 128-byte buffers. Provisional composition and a widget paste
  transaction each have a 4 KiB budget. Committed text also obeys its model's
  capacity: 128 bytes for the prompt field and 4096 for its directory field.
- Widgets and their projection are borrowed only until preparation returns.
  Stack-formatted strings must be drawn before their scope ends, or copied into
  frame-owned storage before appending a widget. Async consumers never retain
  a widget, `Canvas`, context or projection pointer.
- The renderer owns atlas/page memory and its existing quotas. Image decoding
  and external work stay on bounded media/observation workers. A widget draws a
  resource identifier rather than loading or decoding an image in `draw`.
- There is one presentation in flight. Its token publishes matching hit maps
  and retires only captured model damage on successful completion. Failed
  delivery preserves previously delivered controls; newer changes remain
  pending. See the [presentation contract](../../client/presentation/README.md).

`zig build test-gui` covers actual chrome composition, borrowed input ownership,
layout bounds, widget-list capacity/order, warm allocation-free drawing, delayed
presentation, gesture routing and animation deadlines. `zig build test-client
check-client-boundaries codestyle` checks shared client behavior and boundaries.
Run native window checks on each host when changing its bridge. On Linux also
run `test-gui-ime`, `test-gui-clipboard-reader`, `test-gui-keyboard` and
`test-gui-pointer`. These check protocol batching, UTF-8 ranges, backpressure,
physical ownership and fractional scroll independently of a running compositor.

## Agent panes

A pane whose runtime kind is `agent` uses `ThreadPane` with a native header,
structured conversation and an `AgentComposer` card. The GUI
advertises `HostCapabilities.agent_panes`; the shared `new-agent-tab` action
creates a Codex tab through the same controller for bindings, the command
palette and Lua actions. The default binding is prefix + a.

`ThreadConversation` folds consecutive commentary, reasoning and tool activity
into an `Agent work` disclosure, closed by default. Prompts, final responses and
system notices remain visible. Messages without a provider phase remain visible
rather than being inferred as commentary. `ThreadWork` paints a single live or
settled header; opening it restores the original rows and their individual tool
disclosures. Hidden rows are neither measured nor registered as selectable text.
The projection holds at most 256 rows, including headers, for the existing
128-item window. It retains no transcript copies or provider state.

Work disclosures reuse the attachment-scoped interaction and scroll anchor
contracts. Their operation is distinct from an individual item's disclosure;
provider thread and turn IDs preserve expansion through streaming and history
page eviction. Each new turn starts folded. Approvals retain their independent
controls outside the transcript. `tests/thread_work.zig` covers folding, page
seams, turn isolation and hidden selection geometry.

The conversation background uses the window's clear color, like a terminal
pane. It does not add a pane-wide fill over the configured theme background,
opacity or blur. Message cards and controls retain their themed surfaces.

The composer uses the pane's client-owned `ComposerField` and revision. Enter
submits the complete draft, Shift+Enter inserts a newline, and clipboard paste
preserves line breaks. The runtime acknowledgement clears only the submitted
revision, so later typing survives. `MultilineLayout` shares grapheme wrapping
between painting, pointer selection and native caret geometry. Native input,
IME, clipboard and accessibility carry the delivered attachment generation;
a replaced attachment cannot inherit an edit or approval. The card embeds a
sans `TextField` without a second background or border. `ComposerLayout`
wraps the model, effort and permissions toolbar in narrow panes; the circular
turn control sends a message or interrupts the running turn. The inset context
surface shows only observed checkout and branch data.

`EditorFont` uses the atlas's complete shaped spans. Painting, selection and
native caret queries share grapheme positions, including stops within ligatures.
Font discovery happens during frame preparation. Native input uses resident
fonts and bounded scratch tables for at most 8 KiB of displayed text, including
preedit. Each iterator uses about 65 KiB of stack storage. Preparing the first
composer reserves one fixed 660 KiB shaping cache in the renderer, with 128
entries and 16 KiB of text. Atlas destruction releases it. Warm cursor queries
and painting reuse this cache without allocation or font discovery.

`ComposerOptions` borrows the provider's bounded model and effort catalog.
`ComposerMenu` publishes owned indices with attachment, catalog, draft-options
and menu generations. Its interaction controller validates all four before
applying a choice through `agent_threads`. Streaming transcript revisions do
not retire unchanged menus. Keyboard navigation, pointer capture and native
accessibility use the same delivered targets; outside presses dismiss the
menu and consume their release. Held keys retain their original owner, and
closing a menu restores its own pane's composer. Model and effort names are
never invented.

`ThreadTranscript` follows the live snapshot until the user scrolls into history.
Historical reading owns two bounded pages and freezes the initial live seam;
streaming continues to update the composer, approvals and agent status. Scrolling
to either edge records navigation intent without allocating. After successful
frame delivery, the client admits at most one history request per connection.
At most 16 reading windows are retained, each below 192 KiB; admission evicts an
inactive reader when the quota is full. Failed requests preserve the current page
and retry only after another scroll gesture.

Delivered row anchors preserve the reading position across page replacement and
resizing. Provider turn, item ID and fragment offset identify seam duplicates and
disclosure state across live and historical numbering. Copy and link controls
resolve against the owned page and become stale after eviction. Partial messages
render as literal text with a continuation notice and a `Copy segment` action.
`ThreadMessage` separates user bubbles from assistant prose. `MessageText` shares Markdown block and measured-word layout between
measurement and painting; code uses the terminal font. `ThreadActivity` renders
typed tools, dispatch and child-agent cards. Child status never derives from the
parent's status. Only visible messages and activity paint.

Pipe tables use `MessageTable` and `MessageTableCells` to borrow header/body
cells from the snapshot. A matching delimiter row admits at most 32 columns;
malformed or larger tables remain ordinary text. Optional outer pipes, escaped
pipes, CRLF, empty cells and shorter body rows are supported. Surplus body cells
are omitted from both drawing and selected-text copy.
`MessageTablePaint` measures preferred column widths, distributes the available
width and wraps each cell with `MessageTextFlow`. Row height follows the tallest
cell. Headers use a tinted background and bold text; visible rows draw subtle
borders. `MessageTextAlignment` retains at most 256 visible line widths per cell
for left, center or right alignment; lines beyond that quota fall back to left
alignment. This scratch storage is local to synchronous row layout.
Inline styles, Unicode, links and selection retain their source coordinates.
Selected table text copies as tab-separated cells, without the delimiter row;
copying the response still returns the original Markdown. See
[`Markdown tables`](../../../docs/flows/markdown-tables.md) for validation.

`MessageSpans` yields inline link labels with borrowed destination ranges.
`MessageTextFlow` uses the same fragment path for fresh layout and cached replay;
`MessageLinkButton` paints the label and registers only its clipped ink bounds.
These passive targets retain source offsets and snapshot identity, preserve
editor focus and forward wheel input to their owning transcript. Link registration
is capped at 64 fragments per frame, with 64 registry slots reserved for ordinary
controls.

`interaction/message_links` resolves hover from delivered targets against the
current snapshot and copies at most 4 KiB into `MessageLinkPreview`. The scene
draws that tooltip after conversation clipping, only when the prepared frame
still has the same fragment under the pointer. The tooltip fits the window,
has no input target and requests no animation. Stale generations, replaced
snapshots, menus, modals and pointer departure clear it. Original Markdown stays
in the runtime snapshot and remains the source for copying.

Closed `mermaid` fences use `MermaidBlock` to display a retained diagram image.
Open fences, pending work and render failures keep the original code visible.
Measurement only consults the diagram store; painting visible blocks registers
bounded requests or pins an existing image. The GUI starts work after scene
preparation. Images keep their natural aspect ratio and shrink to the message
width; viewport clipping adjusts texture coordinates without changing layout.
Source identity, exact content, theme and scale guard reuse across updates.
Copying a response always copies its original Markdown.

Long spans use a lazy `MessageLayoutCache` owned by GUI interaction state. It
holds 64 measurements and four visible fragment plans, each capped at 2,048
fragments, in one allocation below 180 KiB per GUI. Entries contain source offsets
and geometry, without borrowing snapshot text. Keys include immutable snapshot
provenance, source span, font
identity and revision, style, width and viewport geometry. Short spans bypass
the cache; a plan that exceeds its quota falls back to the measured layout.
Replacing fonts or discovering a fallback also invalidates the atlas's shaping
entries. Animation can reuse unchanged layout and visible fragments.

Scroll position uses logical 24-point units; the delivered transcript target
carries its actual pixel step and limit. At zero the view follows new output.
`ThreadItemControl` identifies pane, attachment and stable runtime item, with no
borrowed text or row index. Expansion and copy resolve that identity again before
acting, so eviction and replacement cannot redirect stale input. The GUI retains
at most 128 open disclosures. A bounded reading anchor preserves the selected
row through streaming and reflow when expanding or collapsing. The next
preparation resolves its position;
successful delivery commits the scroll only if its attachment, sequence and
manual-scroll baseline still match. Failed delivery leaves the anchor available
for retry. Explicit navigation supersedes it.

`ActivityText` requests the scene clock only for visible active labels. It changes
opacity over already-shaped glyph quads, preserving layout and the atlas cache.
There are no per-item timers. Completed and hidden messages leave no deadlines.

Pending approvals expose Approve, Decline and Review full request. The review
control shows the complete bounded request in the scrollable body, independently
of whether the conversation retains a matching tool item.

All controls publish owned pane IDs, attachment generations and approval IDs.
Widgets call shared agent controllers and never send composer text as terminal
input. The existing terminal thread projection retains its passive rendering.
GUI tests exercise multiline IME, prefix routing from the composer, complete
prompt submission, paste overflow, stale accessibility edits, approval
replacement, review scrolling, selector navigation, stale menu decisions and
allocation-free warm card/popover rendering, stable disclosures, original-text
copying, Markdown layout and visible-only animation deadlines.
