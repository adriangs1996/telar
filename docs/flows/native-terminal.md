# Native terminal window

The native client displays the terminal leaves of the shared active-tab layout.
The whole measured grid belongs to the workbench. There are no tab, sidebar,
border or split controls in this increment; existing terminal leaves are not
rejected. Nonterminal surfaces are not implemented by this renderer yet.

## Ownership and entrypoints

`src/cli/client.zig` connects to the runtime and prepares options. `src/gui/run.zig`
transfers those resources to `Application`, which constructs `GuiClient` after
the first valid font and window measurement. The shared `AttachedClient` lives at
one stable heap address. Every host port is bound before the first event.

`RuntimeDriver` owns one asynchronous receive and one asynchronous send. Workers
publish a completion flag and wake the native loop through an owner-held,
nonblocking pipe. The window thread joins the completed operation before calling
`runtime_io.handleRead` or `runtime_io.handleSent`. A receive buffer remains
borrowed until synchronous dispatch finishes. No worker accesses the model.

This bridge is provisional. Step 9 of `docs/plans/native-client-split.md` replaces
it with the inbox/outbox execution model. It contains no general scheduler.

## Three verification cuts

1. Session and display: `bootstrap` queues `configure_graphics`,
   `configure_terminal_colors` and `request_runtime_state`. The shared
   `client_layout_snapshot` handler issues `open_pane`; shared controllers consume
   `pane_opened`, membership snapshots and `pane_frame`. `TerminalRenderer`
   borrows the projection, resolves the shared layout and draws each terminal
   leaf's cells and cursor. A presentation token captures only rendered panes.
   `ApplyPaneFrameHandler` acknowledges validated, owned cells immediately.
   Additional patches update that model while the GPU owns an older submission.
   GPU completion consumes the presentation token through
   `DeliverPresentationHandler`, which retires captured damage and flushes
   released graphics credits. Failure preserves damage for another preparation;
   it does not undo application ACKs. A stale completion cannot retire a newer
   flight, and the next draw captures the latest accumulated state.
2. Input: AppKit text input or Wayland/XKB produces owned semantic keys and
   committed UTF-8 text. `NativeInput` admits bounded input and forwards keys via
   `pane_inputs.send`. Paste uses `pane_pastes.start/content/finish`, whose
   delivery uses the same pane-input controller and a captured pane identity.
   Cmd+V on macOS and Ctrl+Shift+V on Linux read the native clipboard. Application
   multiplexer bindings are not activated without corresponding native UI.
3. Geometry and detach: window size and font scale determine complete columns,
   rows and exact cell pixels. `ResizeHostHandler` and the shared resource
   controllers deliver `pane_resize` through the existing geometry authority.
   Trailing pixels belong to chrome. Closing a window stops GPU consumers, then
   cancels and joins socket tasks before releasing the shared model. It does not
   send a pane-close or runtime-stop command. A new GUI can reattach to the same
   running shell through the ordinary runtime discovery flow.

## Bounds and recovery

- At most 65,536 visible grid cells, with capacity for 24 quads per cell, one
  1,024-square alpha atlas and one native GPU submission. Steady drawing reuses
  quad storage; font changes replace the atlas after the prior consumer ends.
  Retained cell meshes additionally reserve at most 24 quads plus their visual
  key per grid position. Capacity grows only at geometry changes and is bounded
  by the same cell limit. Shrinking a window retains its previous capacity.
- The atlas caches bold and italic variants. Unknown glyphs use the font's
  replacement glyph. A full page uses replacement glyphs reserved at setup.
- Native input holds at most 1,024 items. Clipboard transfers are limited to
  64 KiB and a whole paste is admitted or rejected before its first marker.
  Outbox capacity gates input consumption; send completion resumes it.
- Linux bounds clipboard offers to 16 and keymaps to 4 MiB. Clipboard reads are
  nonblocking. Repeat uses native-loop deadlines; drawing uses Wayland frame
  callbacks and a 60 Hz budget, with no periodic timer or idle repaint.
- On macOS, rendering requests 60 Hz through a demand-driven `CADisplayLink`
  that paces the Metal 4 renderer, with immediate drawing after idle. Commit feedback
  dispatches delivery to the window thread. The GUI requires macOS 26 and a
  Metal 4-capable GPU. Linux uses Vulkan 1.3, dynamic rendering, Synchronization2
  and swapchain maintenance1. One worker waits for its render fence before returning a
  token; an out-of-date presentation retries without retiring damage. Neither GPU consumer
  borrows the shared model. See [Vulkan rendering](vulkan-renderer.md) for
  ownership, shader compilation, compositor pacing and presentation lifetimes.
- Shared graphics storage retains runtime image messages under existing quotas
  and credit accounting, but this increment does not display images. Native
  chrome, attachment UI, bars, config watching, plugins and external notification
  delivery are not implemented here. Their ports are explicitly bound; absent
  visual surfaces do no work, and unsupported requested external operations
  report unavailability. An unavailable clipboard write leaves the terminal live.
- Transport or unrecoverable GPU errors end this client. The runtime remains
  authoritative and the next attachment requests snapshots. No runtime or IPC
  schema changes are required.

## Retained preparation and shaping

`text/ShapingCache` owns 256 entries for the atlas's current font and size.
Entries copy at most 64 UTF-8 bytes and 32 HarfBuzz glyphs/positions. Hash
collisions replace entries; longer runs bypass the cache. Font-size changes
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

Step 9 can replace the temporary driver while keeping these caches, projection
preparation and the existing sealed-frame/completion contract. If preparation
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
session. Completion is not physical display scanout, and a TUI host-write timing
is not the same measurement endpoint.

The [Metal 4 renderer flow](metal4-renderer.md) describes display-link scheduling,
argument tables, residency, completion ownership and shutdown.
