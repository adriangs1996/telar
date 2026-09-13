# Native multiplexer validation on Linux

`tools/vm/gui-multiplexer-test.py` drives the native Wayland client with real
keyboard events and reads shell-written markers to validate their destination.
It uses the existing QEMU/Sway machine, not the host desktop.

```sh
python3 tools/vm/gui-multiplexer-test.py .zig-out/gui-multiplexer-test
```

For parallel integration work, the coordinator first syncs the integration
branch and builds the guest executable. The probe then uses that exact binary
without changing guest sources, caches or artifacts:

```sh
python3 tools/vm/gui-multiplexer-test.py .zig-out/gui-multiplexer-test --skip-build
```

`--binary` accepts an absolute guest executable or a path relative to
`$HOME/src/telar`. `--mode default|configured|both` selects the test matrix.
The default matrix uses Ctrl+B and built-in bindings. The configured matrix
uses Ctrl+S and an explicit Lua binding for vertical splitting.

Each run owns a random directory under `/tmp`, its runtime socket, history,
configuration, and XDG data/cache directories. Every input operation checks that
the exact GUI PID owns Wayland keyboard focus. Cleanup closes only that GUI and
stops only the isolated runtime. Existing sessions are never stopped.

The matrix checks:

- Workspace and tab naming through native prompts and subsequent goto lookups.
- Both split directions, directional focus, pane resizing and pane fullscreen.
- Sidebar visibility, keyboard resizing and workspace-list collapse.
- Sidebar pointer dragging through Sway seat events when its compositor exposes
  that operation and a measurable cell grid. An unavailable pointer driver is
  recorded explicitly; a supported drag with wrong geometry fails the run.
- Tab positions, next/previous selection, reordering, creation and close.
- Workspace creation, rename and switching; pane creation and close.
- Detach/reattach with five live shells. Pane IDs, generations, workspace IDs,
  tab IDs and shell PIDs must remain identical. The three original split panes
  must also retain their PTY row/column sizes at the same window dimensions.
- Vulkan core and synchronization validation without errors in either client.

`wtype` delivers keyboard events. The optional pointer path uses the documented
[Sway seat cursor commands](https://github.com/swaywm/sway/blob/master/sway/sway-input.5.scd).
Those commands are deprecated in favor of the virtual-pointer protocol; their
availability is checked before pointer assertions begin.

Results include `results.json`, bounded copies of both GUI logs and screenshots
at each major state. Each shell marker is written atomically and includes
`TELAR_PANE_ID`, `TELAR_PANE_GENERATION`, `TELAR_WORKSPACE_ID`, `TELAR_TAB_ID`,
`$$`, and `stty size`. A command arriving at the wrong shell fails even if the
window looks plausible. Each marker and process wait has a fixed deadline.

The script is a functional and lifetime regression probe. It does not measure
latency, prove multi-day stability, or replace the TUI/runtime regression suites.
