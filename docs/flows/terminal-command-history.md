# Terminal command history

The runtime's `history/Observer` replays bounded input, output and resize batches
into its own disposable terminal. `TerminalTracker` uses that terminal to recover
shell edits, capture submitted commands and observe their completion. This work
runs on the observation path; it does not read or mutate the live pane's VT state.

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

`src/backend/history/terminal.zig` covers alternate input followed by resize,
screen changes during an edit or pending submission, initialization and teardown
with alternate active, and completion of a running command. `zig build test`
includes these regressions. `tools/gui_text_input.py` additionally checks native
GUI startup and repeated input through a directly launched Neovim process.
