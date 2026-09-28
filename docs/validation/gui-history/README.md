# Native command history

Captures of the history panel on macOS, driven against an isolated runtime by
`tools/gui_history.py`, which builds the AppKit driver in `tools/gui_actions.m`,
runs a few shell commands, opens the panel with `prefix+/`, toggles the inspector
with Ctrl+O, filters failed commands with `!`, searches and closes it.

```sh
zig build install
python3 tools/gui_history.py zig-out/bin/telar /tmp/telar-history-check
```

The tool writes `history-list.png`, `history-inspector.png`, `history-failed.png`
and `history-search.png` into the directory and checks that the shell's pid and
size are the same before and after the panel. `screencapture` needs the Screen
Recording permission of the terminal that runs the tool; without it every
capture logs `could not create image from window` and the run fails on the
missing files while the driven sequence still completes.

`tools/gui_history_typing.py` takes the same two arguments. It types a query
into the open panel, records every frame the window submits and fails when a
frame dims the rows or draws the loading line, which is how a keystroke used
to flash the panel. It needs no Screen Recording permission.

The automated coverage lives in `src/gui/tests/history_modal.zig`,
`src/gui/tests/history_rendering.zig` and `src/gui/tests/overlays.zig`: row
selection without submission, stale-page rejection, chip clicks, inspector
scroll bounds, entrance geometry, narrow and high-density windows and warm
repaints with zero shaping and zero allocation.
