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

The worker alone writes and closes the published nonblocking transfer descriptor.
A release/acquire flag returns each slot to the window producer after close. Full
queues reject the requested transfer by closing its descriptor; closed consumers
and transfers exceeding five seconds retire independently. SIGPIPE is blocked
only on this worker. Window shutdown revokes admission, wakes and joins the worker,
then releases its storage and Wayland resources. No transfer waits on the window
thread or on a frame completion.

Clicking an HTTP(S) link enters the existing shared link controller. Its bounded
queue schedules `ports/services.zig` as an inbox producer, and `.link_opened`
completes the request through the same controller. `telar-client.openHostLink`
contains the worker formerly owned by the TUI: `/usr/bin/open` on macOS and
`xdg-open` on Linux, with a five-second timeout and 4 KiB limits for each output
stream. The TUI imports that same function through its previous namespace;
commands and failure behavior are unchanged. File links continue to use the
configured editor in a shared command tab.

`zig build test-gui-clipboard` on Linux verifies snapshot ownership, saturation,
closed consumers and cancellation of a stalled transfer without a compositor.
The native clipboard tests also run under address and undefined-behavior
sanitizers. Client tests verify unsupported URI schemes cannot spawn a process;
the existing frontend suite covers the unchanged shared link routing.
