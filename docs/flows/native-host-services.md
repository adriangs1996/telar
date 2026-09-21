# Native clipboard and link services

GUI copy-mode yank and runtime clipboard messages already reach the shared
`HostClipboard` port. macOS writes UTF-8 text to `NSPasteboard`. Linux now publishes
that text as a `wl_data_source` on its existing seat data device, using the most
recent keyboard focus/input serial. Incoming paste continues through the same
native input queue and shared paste owner.

`src/gui/linux/clipboard.c` owns the outgoing selection and transfer lifecycle.
The clipboard and each of four transfer slots hold at most 64 KiB, matching the
wire clipboard limit. A compositor send callback copies one immutable snapshot
into a free slot and wakes one worker. Replacing the selection cannot overwrite
bytes already being pasted into another application.

The live worker alone writes and closes the published nonblocking transfer descriptor.
A release/acquire flag returns each slot to the window producer after close. Full
queues reject the requested transfer by closing its descriptor; closed consumers
and transfers exceeding five seconds retire independently. SIGPIPE is blocked
only on this worker. A fatal polling error revokes admission before worker cleanup.
Window shutdown revokes admission, wakes and joins the worker, then closes any
descriptor whose publication raced with that cleanup. The window producer has
stopped before this final pass. Storage and Wayland resources are released last.
No transfer waits on the window thread or on a frame completion.

Clicking an HTTP(S) link enters `operations/input/link_openings.apply`. Its
bounded queue schedules `ports/services.zig` as an inbox producer; `.link_opened`
reaches `link_openings.complete` through `GuiClient.update`. `telar-client.openHostLink`
contains the worker formerly owned by the TUI: `/usr/bin/open` on macOS and
`xdg-open` on Linux, with a five-second timeout and 4 KiB limits for each output
stream. The TUI imports that same function through its previous namespace;
commands and failure behavior are unchanged. File links continue to use the
configured editor in a shared command tab; agent message files open beside their
source pane.

Right-clicking a terminal link copies its URI without keyboard modifiers. The
native chrome port resolves the target only from delivered pane content and
queues the existing bounded clipboard write. `PointerRouting` consumes drag and
release without forwarding them to the child. Agent message links use their
snapshot-validated destination and the same clipboard service. The TUI dispatches
right-button link gestures through `link_openings` to `HostClipboard`.
`link_regressions.zig` verifies copying without opening or child mouse reports.

Link copy requests retain only the latest host request ID in `CopyFeedback`.
`NativeInput.dispatchClipboard` first validates completion through the host
service; only a successful matching write displays "Copy to clipboard". The
passive label sits above the bottom status bar for two seconds, using the frame
clock's expiration deadline rather than a polling timer. It never enters the
notification history or claims pointer input. Failed, duplicate and replaced
requests cannot display a confirmation.

Hovering a terminal URI shows the hand cursor even without modifiers. Opening
still uses the existing platform modifier and child mouse-reporting policy.
Agent message links resolve the delivered widget and current snapshot before
showing the same hand; stale links, modals and pointer departure remove it.

`zig build test-gui-clipboard` on Linux verifies snapshot ownership, saturation,
closed consumers, polling failure, late publication and cancellation of a stalled
transfer without a compositor.
The native clipboard tests also run under address and undefined-behavior
sanitizers. Client tests verify unsupported URI schemes cannot spawn a process;
the existing frontend suite covers the unchanged shared link routing.

`python3 tools/vm/gui-clipboard-test.py /tmp/telar-gui-clipboard --skip-build`
uses the prepared Wayland VM binary to check the complete copy path. It reuses
the multiplexer test's isolated runtime and verified window focus. Each default
and configured prefix run copies ASCII and UTF-8 text from copy mode, compares
both advertised clipboard MIME types through `wl-paste`, then pastes the same
bytes back into the original shell with Ctrl-Shift-V. Screenshots and results
are stored per configuration. Run it sequentially with the other native VM
tests; their keyboard and pointer injections share one compositor seat.
