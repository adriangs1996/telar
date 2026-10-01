# Native terminal window

This document records the original terminal-only delivery path. Current chrome
and navigation are described in [native multiplexer](gui-multiplexer.md), and
font fallback in [native appearance](native-appearance.md#configuration-and-fonts).

The native client displays the terminal leaves of the shared active-tab layout.
The whole measured grid belongs to the workbench. There are no tab, sidebar,
border or split controls in this increment; existing terminal leaves are not
rejected. Nonterminal surfaces are not implemented by this renderer yet.

## Ownership and entrypoints

`src/cli/client.zig` connects to the runtime and prepares options. `src/gui/run.zig`
constructs one heap-owned `GuiAdapter` and calls its `run`. It owns `Client`,
`NativeLoop`, `TerminalRenderer`, input, widgets, cursor and window state.
Every host port is bound to its final address before events arrive.

`native/window_callbacks.zig` adapts the C ABI without owning state. Both native
backends notify `windowReady` when surface geometry is available: macOS after
sizing its drawable, Wayland after acknowledging surface configuration. The
first usable measurement starts the runtime; repeated notifications do not
repeat bootstrap. `draw` never initializes the connection.

`GuiAdapter.update` drains events and computes cursor and redraw decisions.
`draw` applies pending configuration and measures geometry only after the prior
frame retires, then seals the next presentation. Native callbacks return token
zero while a prior frame is busy. Native GPU consumers stop before `deinit`,
which joins loop workers before releasing renderer and client resources.

`NativeLoop` connects the shared bounded inbox to an owner-held nonblocking
wake pipe. Socket workers publish validated `RuntimeMessage` values or send
completions into reserved slots. The window thread drains a finite FIFO batch
and delegates to `runtime_io.receiveRuntime` or `runtime_io.completeRuntimeSend`. A receive
buffer remains borrowed until synchronous dispatch finishes. No worker accesses
the model. Input readiness, focus and GPU completion use that same inbox.

`ConfigurationReload` reserves a completion slot for its config/font worker.
The window thread adopts a prepared generation after native consumers finish.
See [native appearance](native-appearance.md#hot-reload) for the swap and cleanup,
and [client event dispatch](client-event-dispatch.md) for admission, drain
budgets, wakeups and shutdown shared with the headless client and the test
drivers.

## Three verification cuts

1. Session and display: `GuiAdapter.start` queues `configure_graphics`,
   `configure_terminal_colors` and `request_runtime_state` through
   `model.to_runtime.pushBootstrap`. The shared
   `client_layout.restoreClientLayout` issues `open_pane`; shared operations consume
   `pane_opened`, membership snapshots and `pane_frame`. `TerminalRenderer`
   borrows the projection, resolves the shared layout and draws each terminal
   leaf's cells and cursor. A presentation token captures only rendered panes.
   `pane_frame.receive` applies validated, owned cells and queues their ACK in
   `model.to_runtime`; `pane_frames.receivePaneFrame` sends it immediately.
   Additional patches update that model while the GPU owns an older submission.
   GPU completion consumes the presentation token through
   `presentation_delivery.apply`, which retires captured damage and flushes
   released graphics credits. Failure preserves damage for another preparation;
   it does not undo application ACKs. A stale completion cannot retire a newer
   flight, and the next draw captures the latest accumulated state.
2. Input: AppKit text input or Wayland/XKB produces owned semantic keys and
   committed UTF-8 text. `GuiAdapter` admits bounded input into `InputQueue` and forwards keys via
   `pane_input.sendPaneInput`. Paste uses `pane_input.startPanePaste`,
   `appendPanePaste` and `finishPanePaste`, whose delivery uses the same
   pane-input operation and a captured pane identity.
   Cmd+V on macOS and Ctrl+Shift+V on Linux read the native clipboard. Application
   multiplexer bindings are not activated without corresponding native UI.
3. Geometry and detach: window size and font scale determine complete columns,
   rows and exact cell pixels, after the chrome bands (`ChromeMetrics`) are
   taken off the window height. `host_resize.applyHostUpdate` calls
   `pane_resize.resizeAttachedPanes` to deliver `pane_resize` through the existing geometry authority.
   Trailing pixels belong to chrome. Closing a window stops GPU consumers, then
   cancels and joins socket tasks before releasing the shared model. It does not
   send a pane-close or runtime-stop command. A new GUI can reattach to the same
   running shell through the ordinary runtime discovery flow.

## Bounds and recovery

- At most `core.max_cell_count` (130,359) visible grid cells, with capacity
  for 24 quads per cell, one active alpha atlas of 1,024 or 2,048 texels a
  side and one native GPU submission. A larger viewport keeps its columns and
  the rows that fit. A font reload
  can additionally hold one staged or retired renderer. Steady drawing reuses
  quad storage; font changes replace the atlas after the prior consumer ends.
  Retained cell meshes additionally reserve at most 24 quads plus their visual
  key per grid position. Capacity grows only at geometry changes and is bounded
  by the same cell limit. Shrinking a window retains its previous capacity.
- The atlas caches face-specific bold and italic variants. Missing graphemes
  try embedded text and Nerd Symbols faces before the primary replacement glyph.
  A glyph that finds the page full draws the replacement glyph reserved at
  setup for that frame; the page is emptied before the next one, and a page
  a single frame fills reopens at 2,048 texels.
- Native input holds at most 1,024 items. Clipboard transfers are limited to
  1 MiB and a whole paste is admitted or rejected before its first marker; a
  refused paste reports `gui.clipboard.max_text_bytes`.
  `model.to_runtime` capacity gates input consumption; send completion resumes it.
- Linux bounds clipboard offers to 16 and keymaps to 4 MiB. Clipboard reads are
  nonblocking. Repeat uses native-loop deadlines; drawing uses Wayland frame
  callbacks and a budget of the output's refresh rate
  ([frame pacing](frame-pacing.md)). A visible blinking cursor adds one deadline
  per phase; a steady scene has no animation timer or idle repaint. Config
  watching checks fingerprints once a second off the native thread.
- On macOS, rendering requests the display's refresh rate through a demand-driven `CADisplayLink`
  that paces the Metal 4 renderer, with immediate drawing after idle. Commit feedback
  dispatches delivery to the window thread. The GUI requires macOS 26 and a
  Metal 4-capable GPU. Linux uses Vulkan 1.3, dynamic rendering, Synchronization2
  and swapchain maintenance1. One worker waits for its render fence before returning a
  token; an out-of-date presentation retries without retiring damage. Neither GPU consumer
  borrows the shared model. See [Vulkan rendering](vulkan-renderer.md) for
  ownership, shader compilation, compositor pacing and presentation lifetimes.
- Shared graphics storage retains runtime image messages under existing quotas
  and credit accounting, but this increment does not display images. Native
  chrome, attachment UI, bars, plugins and external notification
  delivery are not implemented here. Absent visual surfaces do no work;
  `GuiAdapter.deliverHostEffects` drops terminal notifications from
  `model.to_host` and answers media capture as unavailable. An unavailable
  clipboard write leaves the terminal live.
- Transport or unrecoverable GPU errors end this client. The runtime remains
  authoritative and the next attachment requests snapshots. Cursor appearance
  and the host's ANSI defaults extend the IPC schema; runtime and client must
  use matching builds. See [native appearance](native-appearance.md).

## Retained preparation and shaping

`text/ShapingCache` owns 384 entries for the atlas's current font set and size.
Entries copy at most 64 UTF-8 bytes and 32 HarfBuzz glyphs/positions, plus the
source face identity. Single-byte ASCII for the primary face has 128 dedicated
slots; every other run hashes into one of 64 four-way sets, so up to four
colliding labels stay cached and a fifth replaces the set's round-robin
victim. Longer runs bypass the cache. Font-size changes
invalidate it, and font replacement creates a new cache. Location and color
are applied after shaping; bold/italic still select separate rasterized atlas
slots. Warm hits allocate nothing. The cache belongs to the text renderer,
not the runtime driver or a window callback.

`render/RetainedCells` owns each grid position's visual key and `CellMesh`.
The key includes the complete cell (text, width, colors and flags) and its
resolved pixel rectangle. Preparation compares the latest projection with
these owned values and recompiles only mismatches. It does not consume or
clear `Pane.damage_rows`, which remain governed by successful delivery.
Comparing final visual values also handles skipped revisions, geometry ABA,
reattachment, failed delivery, and changes that are reverted before preparation.
A newly received frame still contributes its presentation commit even when its
visual contents match the cache.

Default backgrounds use the native render-pass clear. Nondefault backgrounds
precede all glyphs in each pane, including wide-cell continuations. Spaces skip
shaping but retain backgrounds and decorations. The cursor is composed
separately, so cursor movement does not recompile cell geometry. Theme changes,
font replacement and grid resizing invalidate the affected retained state.
New selection/search styling must resolve into the visual key before lookup;
changes to global font/rendering policy must invalidate retained meshes.

Preparation costs O(visible cells + emitted quads), with shaping and mesh
compilation restricted to changed cells and cache misses. This is CPU damage
tracking, not a retained GPU framebuffer: both native backends still submit a
complete sealed scene. Their swapchain drawables need no preserved contents,
and failed presentation can retry the same prepared geometry. Neither cache
stores a presentation token, model pointer or transport state.

The inbox/outbox driver retains these caches, projection preparation and the
existing sealed-frame/completion contract. If preparation
later moves to a worker, its owner must transfer/copy visual input and retain
the cache there; the worker must never borrow the mutable client model.

## Reproducible checks

`zig build test-gui` covers rendered frame completion, failed and stale tokens,
repeated ACKs without keyboard, native input ownership and atomic paste
admission, bracketed paste, exact grid metrics, multiple terminal leaves,
clipping, atlas fallback and cancellation of a blocked socket read.

`zig build test-gui-window` on macOS opens a real Metal window and checks frame
completion plus the native mapping of text, Ctrl+C, Enter and UTF-8 insertion.
This explicit window test is separate from the ordinary headless test suite.

With the existing Linux VM running, execute:

```sh
python tools/vm/gui-terminal-test.py /tmp/telar-gui-validation
```

The script uses a separate runtime and history directory, captures the prompt
after 50 output updates, types a command, pastes through Wayland, compares
`stty size`, closes the window and checks that reattachment returns the same
shell PID. Screenshots are retained in the supplied output directory. Cleanup
stops only that test window and its isolated runtime.

Also run `zig build test`, `zig build codestyle` and
`zig build check-client-boundaries`. No implementation changes belong to
`src/client` for this increment.

On macOS, measure key dispatch through matching terminal geometry and successful
Metal completion with an isolated runtime:

```sh
zig build -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/telar-profile
python3 tools/gui_latency.py /tmp/telar-profile/bin/telar /tmp/telar-echo-empty
python3 tools/gui_latency.py /tmp/telar-profile/bin/telar /tmp/telar-echo-dense --dense
```

Use new result directories. The test-only injected library sends alternating
`x` and erase to `cat`, and waits for the expected glyph count's GPU token
before sending another key. It retains individual samples, viewport dimensions,
summary statistics and optional phase traces. It requires a graphical login
session. Completion is not physical display scanout.

The [Metal 4 renderer flow](metal4-renderer.md) describes display-link scheduling,
argument tables, residency, completion ownership and shutdown.
