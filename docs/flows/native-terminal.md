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
   GPU completion consumes that token through `DeliverPresentationHandler`, which
   flushes graphics credits before `frame_ack`. Failure and cancellation do not
   ACK. A stale completion cannot retire a newer flight.
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
- The atlas caches bold and italic variants. Unknown glyphs use the font's
  replacement glyph. A full page uses replacement glyphs reserved at setup.
- Native input holds at most 1,024 items. Clipboard transfers are limited to
  64 KiB and a whole paste is admitted or rejected before its first marker.
  Outbox capacity gates input consumption; send completion resumes it.
- Linux bounds clipboard offers to 16 and keymaps to 4 MiB. Clipboard reads are
  nonblocking. Repeat and drawing use native-loop deadlines, with no idle poll.
- Rendering is capped at 60 Hz. Metal reports command completion on the window
  thread. Vulkan uses one worker and waits for its fence before returning a
  token; an out-of-date presentation retries without ACK. Neither GPU consumer
  borrows the shared model.
- Shared graphics storage retains runtime image messages under existing quotas
  and credit accounting, but this increment does not display images. Native
  chrome, attachment UI, bars, config watching, plugins and external notification
  delivery are not implemented here. Their ports are explicitly bound; absent
  visual surfaces do no work, and unsupported requested external operations
  report unavailability. An unavailable clipboard write leaves the terminal live.
- Transport or unrecoverable GPU errors end this client. The runtime remains
  authoritative and the next attachment requests snapshots. No runtime or IPC
  schema changes are required.

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
