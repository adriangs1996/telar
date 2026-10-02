# Native command history

Captures of the history panel on macOS, driven against an isolated runtime by
`tools/gui_history.py`. It builds the AppKit driver in `tools/gui_actions.m`,
imports the harmless commands of `tools/history_fixture.py` (three days of
short commands, one with wide and combining characters, one over several
lines and one longer than a card), types a few more into a throwaway shell,
one of them longer than a row, and opens the panel with `prefix+/`. It then
walks to the long commands with Up, selects a row with a click, toggles the
inspector with Ctrl+O, filters failed commands with `!`, searches, closes
the panel, and finally runs the long command from the history and pastes it
again.

```sh
zig build install
python3 tools/gui_history.py --frames zig-out/bin/telar /tmp/telar-history-check
```

The tool writes `history-list.png`, `history-long.png`,
`history-multiline.png`, `history-script.png`, `history-click.png`,
`history-inspector.png`, `history-failed.png` and `history-search.png` into
the directory. It checks that the shell's pid and size are the same before
and after the panel, and that typing, running and pasting the long command
each ran the whole of it. Nothing reads the user's own history.

`--frames` takes the pictures from the frames the window presented, through
`tools/gui_capture.m`, and needs no permission. Without it the tool calls
`screencapture`, which needs the Screen Recording permission of the terminal
that runs the tool; without that permission every capture logs
`could not create image from window` and the run fails on the missing files.
`--size 1180x720` asks for a window size. A window manager that tiles the
window ignores it; `--font-size 64` then makes the same window small in
logical pixels, which is what the layout measures, and reaches the narrow
panel where the inspector replaces the list.

To look at the panel by hand, load the same fixture into the development
runtime and open it with `prefix+/`:

```sh
just app
python3 tools/history_fixture.py /tmp/telar-fixture.zsh_history
just run history import zsh --file /tmp/telar-fixture.zsh_history
```

`tools/gui_history_typing.py` takes the same two arguments. It types a query
into the open panel, records every frame the window submits and fails when a
frame dims the rows or draws the loading line, which is how a keystroke used
to flash the panel. It needs no Screen Recording permission.

The automated coverage lives in `src/gui/tests/history_modal.zig`,
`src/gui/tests/history_rendering.zig` and `src/gui/tests/overlays.zig`: row
selection without submission, stale-page rejection, chip clicks, the card's
copy and delete controls, inspector scroll bounds, entrance geometry, the
panel following the window, the selection's motion, long and multi-line
commands shown complete, narrow and high-density windows and warm repaints
with zero shaping and zero allocation.
