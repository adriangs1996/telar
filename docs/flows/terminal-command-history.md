# Terminal command history

The runtime's `history/Observer` replays bounded input, output and resize batches
into its own disposable terminal. `TerminalTracker` uses that terminal to recover
shell edits, capture submitted commands and observe their completion. This work
runs on the observation path; it does not read or mutate the live pane's VT state.

Each pane alternates two batches of 128 KiB and 512 events
(`history.observer_batch_bytes`, `history.observer_batch_events`). A burst
that does not fit before the next observation pass drops the batch and resets
the disposable terminal, so a command in flight during that burst is not
recorded; the pane's own screen is untouched. A captured command the full
history queue (`history.request_queue`, 64 requests) refuses is lost the same
way. `pane_observation.finish` reports either limit on the event loop with
the limit notice.

`telar history import` sends commands of up to 64 KiB less one byte
(`history.import_command_bytes`), what the wire's sized16 field carries. A
longer command is skipped whole, never cut; the rest are imported, and the
command prints the limit notice, reports it to the runtime and exits 1.

Configured `command_filters` and `cwd_filters` hold 64 patterns of 256 bytes
each (`history_filter.max_patterns`, `history_filter.max_pattern_bytes`). A
list or pattern past its limit refuses the configuration with the limit's
name, since dropping a filter would record the commands it hides.

The edit anchor and right-prompt boundary are tracked pins owned by the primary
screen's page list. Creation, cursor copies, selections and release must use that
same page list, including when the active screen is alternate during shutdown.
Copying an alternate-screen cursor into a primary tracked pin breaks resize
tracking and can leave the pin pointing outside its page.

Alternate-screen input cannot start or complete a shell edit. Entering alternate
cancels an unsubmitted edit or a submission awaiting capture. It leaves commands
already running intact: their output tail, OSC completion and process completion
continue through the existing tracker. This also handles a full-screen program
launched directly as the pane's root process, whose foreground process identity
alone cannot distinguish it from a shell.

The native Neovim probe exposed this ownership error during GUI startup. Its
Debug runtime crashed after alternate-screen input followed by resize and output.
The original tracker also fails a deterministic test of that sequence; successful
startup runs alone therefore do not establish valid pin ownership.

`lib/cmdcapture/terminal.zig` covers alternate input followed by resize,
screen changes during an edit or pending submission, initialization and teardown
with alternate active, and completion of a running command. `zig build test`
includes these regressions. `tools/gui_text_input.py` additionally checks native
GUI startup and repeated input through a directly launched Neovim process.
