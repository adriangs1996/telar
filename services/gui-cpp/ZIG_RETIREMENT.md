# Zig retirement

Using the C++ window does not remove every Telar Zig dependency. This migration is
separate from the current graphics, blur and benchmark delivery phase.

| Dependency | Required migration |
| --- | --- |
| Bundled runtime and CLI | Qualify compatible replacements for discovery, runtime requests and retained helper commands |
| Plugin worker | Replace and qualify the Zig one-shot Lua worker used by the C++ broker |
| Generated themes, bindings, actions and tables | Move canonical data to independent inputs and preserve generated values |
| Font dependency metadata | Remove the configure-time read of the FreeType source list in `build/freetype.zig`; the archives are already pinned upstream |
| Shared C, Objective-C, Lua and assets | Retain or relocate these explicitly; they are not Zig code |
| Reference tests and third-party tools | Separate optional original-source oracles from production dependencies; audit Ghostty's toolchain independently |

Before deleting Telar's Zig source tree, build from fresh directories on macOS
and Linux without those sources or stale generated headers/libraries. Package and
relocate the result, exercise the adopted workflows and verify the retained
runtime/helper paths. A successful startup or incremental build is insufficient.

No removal of Telar's Zig sources is claimed by the current client preview.
