# Zig retirement gate — OPEN

Daily adoption and deletion of Zig are separate milestones. The preview currently
ships the original runtime/CLI; it must keep working beside the current app.

| Dependency class | Current use | Required before removal |
| --- | --- | --- |
| Own production Zig | Bundled `telar` supplies runtime, CLI, SSH/runtime discovery and helpers | Qualify compatible replacements for every retained CLI/runtime path; do not rewrite the runtime as part of packaging |
| Own Zig read by GUI generators | `theme_support.zig`, `TerminalTheme.zig`, `Palette.zig`; `default_bindings.zig`; `command_palette.zig`; `unicode_placeholder.zig`; `box_lines.zig`, `BoxLines.zig`, `box_style.zig` | Move canonical data to a language-independent source and prove generated values unchanged |
| Shared own non-Zig sources | `src/client/config/bootstrap.lua`, bundled fonts/assets; `src/gui/macos/font.m`, `src/gui/linux/font.c` and native headers; desktop-mode C++ utilities | Keep or relocate explicitly; these are not Zig code and must not be deleted with it |
| Test oracles | Original-source Zig excerpts, original CLI binaries and paired GUI captures | Preserve immutable evidence; distinguish reproducible migration controls from production dependencies |
| Third-party toolchain | Ghostty VT and its pinned build/toolchain; Qt, Lua, font libraries and diagram renderer have separate build inputs | Audit independently; removing own Zig does not imply removing a third-party Zig compiler requirement |

The generator inventory above comes from `CMakeLists.txt`, including its explicit
`DEPENDS` inputs. It is an initial production inventory, not proof that every
transitive test, packaging or runtime dependency has been removed.

Acceptance requires a fresh build directory with the own Zig source tree absent,
no stale generated headers/libraries, and declared dependency/toolchain inputs.
Build both macOS and Linux, package and relocate the app, run the adopted daily
flows and the remaining parity gates. Record which original oracles are optional
test inputs, which shared C/Objective-C/Lua/assets remain, and any third-party Zig
toolchain still required. Only then can own Zig sources be removed. Never infer
this result from a successful GUI startup.
