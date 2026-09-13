# GUI fonts and held-key validation

The later [procedural Braille validation](braille/README.md) covers the Codex
input animation fix and preserves before/after captures on both platforms.

Validated on 2026-09-13 at code revision `73a59ee3` on macOS and the isolated
Linux Wayland/Vulkan VM. The changes are described in
[font fallback](../../flows/gui-font-fallback.md),
[native input](../../flows/native-input.md) and
[terminal command history](../../flows/terminal-command-history.md).

`zig build install test test-gui` reported:

| Platform | Build steps | Zig tests passed | Skipped | Failed |
| --- | ---: | ---: | ---: | ---: |
| macOS | 129/129 | 3,410 | 2 | 0 |
| Linux | 136/136 | 3,411 | 1 | 0 |

The GUI portion contains 109 tests: all pass on macOS; Linux skips the macOS
optical-weight test. Source style and client boundaries pass. Native window
checks also pass on both platforms, including 26 AppKit repeat checks and Vulkan
validation. The Wayland keyboard listener tests cover timing and cancellation.

Native captures with unpatched DejaVu Sans Mono show embedded Nerd icons on both
platforms. Font tests cover supplementary icons, four styles, compressed cell
spacing and 120 warm repaints without additional shaping, rasterization or
adapter allocation. These checks do not establish pixel equivalence to Ghostty.

The macOS Neovim probe passes two consecutive final Debug runs: one `j` press
plus ten injected repeats moves from line 1 to line 12. These are AppKit event
delivery checks, not hardware repeat generation. In the Linux VM, a 1.2-second
virtual hardware hold delivers 15 `j` bytes to the PTY and stops on release.

The Neovim probe also exposed invalid history pins. Baseline `5f68d56d` passed
two startup runs; the GUI changes before the pin fix crashed two Debug runs.
A deterministic alternate-screen/input/resize/output test reproduces the exact
`rebaseMovedEdit` panic with the original tracker. The ownership fix passes all
74 history tests and both final native Neovim runs, with empty runtime error logs.
Startup timing alone was insufficient to verify that ownership contract.
