# Zig retirement gate — OPEN

Daily adoption and deletion of Zig are separate milestones. The preview currently
ships the original runtime/CLI; it must keep working beside the current app.

| Dependency class | Current use | Required before removal |
| --- | --- | --- |
| Own production Zig | Bundled `telar` supplies runtime, CLI, SSH/runtime discovery and helpers | Qualify compatible replacements for every retained CLI/runtime path; do not rewrite the runtime as part of packaging |
| Own Zig read by GUI generators | `theme_support.zig`, `TerminalTheme.zig`, `Palette.zig`; `default_bindings.zig`; `command_palette.zig`; `unicode_placeholder.zig`; `box_lines.zig`, `BoxLines.zig`, `box_style.zig` | Move canonical data to a language-independent source and prove generated values unchanged |
| Own dependency/build metadata | `cmake/fonts.cmake` reads dependency URLs from `build.zig.zon` and the FreeType C source list from `build/freetype.zig` | Preserve pinned dependency identities and the exact platform source selection in independent build metadata; test a fresh configure without these files |
| Shared own non-Zig sources | `src/client/config/bootstrap.lua`, bundled fonts/assets; `src/gui/macos/font.m`, `src/gui/linux/font.c` and native headers; desktop-mode C++ utilities | Keep or relocate explicitly; these are not Zig code and must not be deleted with it |
| Test oracles | Original-source Zig excerpts, original CLI binaries and paired GUI captures | Preserve immutable evidence; distinguish reproducible migration controls from production dependencies |
| Third-party toolchain | Ghostty VT and its pinned build/toolchain; Qt, Lua, font libraries and diagram renderer have separate build inputs | Audit independently; removing own Zig does not imply removing a third-party Zig compiler requirement |

The generator inventory above comes from `CMakeLists.txt`, including its explicit
`DEPENDS` inputs; the font metadata dependency comes from `cmake/fonts.cmake`,
including its `CMAKE_CONFIGURE_DEPENDS`. It is an initial production inventory, not proof that every
transitive test, packaging or runtime dependency has been removed.

Acceptance requires a fresh build directory with the own Zig source tree absent,
no stale generated headers/libraries, and declared dependency/toolchain inputs.
Build both macOS and Linux, package and relocate the app, run the adopted daily
flows and the remaining parity gates. Record which original oracles are optional
test inputs, which shared C/Objective-C/Lua/assets remain, and any third-party Zig
toolchain still required. Only then can own Zig sources be removed. Never infer
this result from a successful GUI startup.

The second preview executes plugins using the bundled original CLI's
`plugin-worker` oneShot mode. The C++ broker owns copying, process limits,
completion identity and capability checks, but the Lua worker remains own Zig
production code. It must be replaced and independently qualified before removing
that dependency; packaged startup and successful plugin execution do not retire it.

## Observed production graph (2026-11-01)

The [source-bound inventory](measurements/zig-production-inputs.json) records
`ninja -t inputs telar-gui` on both current macOS/Linux builds. Both graphs name
the same nine own Zig generator inputs with identical hashes. macOS additionally
compiles shared `src/gui/macos/font.m`; Linux compiles `src/gui/linux/font.c`.
Both consume the six recorded font/artwork assets. A direct configure-source
audit adds `build.zig.zon`, `build/freetype.zig` and shared `bootstrap.lua`;
these configure reads are not established by Ninja's production-target list.
The package script requires the original runtime/CLI and diagram helper, and
the plugin adapter invokes that CLI's `plugin-worker` mode. The inventory binds
those adapter/build sources and the Preview10 CLI identity.

This is an explicit-input observation, not an exhaustive compiler-header or
transitive runtime audit. Test/oracle sources are not made production
requirements by their presence elsewhere in the repository. Existing imported
Ghostty archives also do not establish a reproducible toolchain-independent
build. No sources were removed and no clean build without own Zig was attempted.
The retirement gate remains open.
