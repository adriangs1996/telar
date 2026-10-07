# Build navigation

`build.zig` is the assembly index. It creates the application, registers the
optional targets, attaches the GUI and hands the cross-platform check to the
release gate. Source paths are always resolved from the repository root
through `b.path`, even from these support files.

| Change | File |
| --- | --- |
| Shipped module graph, dependencies, build options, default install and `run` | [Application.zig](Application.zig) |
| Shared resolved modules and the installer embed | [Modules.zig](Modules.zig) |
| Standalone libraries under `lib/` and their import boundary | [Libraries.zig](Libraries.zig) |
| Optimized benchmark graph, `bench`, `echo-probe`, browser verification | [Benchmarks.zig](Benchmarks.zig) |
| Native GUI modules and `gui` | [gui.zig](gui.zig) |
| macOS adapter sources, Objective-C flags and frameworks | [macos_gui.zig](macos_gui.zig) |
| Wayland protocol generation, Vulkan sources/libraries, GLSL compilation and embedded SPIR-V | [linux_gui.zig](linux_gui.zig), [window.zig](window.zig) |
| macOS bundle/DMG and Linux desktop/archive packaging | [packaging.zig](packaging.zig) |
| `check`, code style, boundaries and release gates | [checks.zig](checks.zig) |
| Linux portability checks | [cross.zig](cross.zig) |
| FreeType/HarfBuzz sources and flags | [freetype.zig](freetype.zig) |
| Pinned brotli, nghttp2 and SQLite, or system copies by `-D<name>=<prefix>` | [native_libraries.zig](native_libraries.zig), [NativeLibrary.zig](NativeLibrary.zig) |
| SDK search paths for a pinned macOS deployment target | [macos_sdk.zig](macos_sdk.zig) |
| Vendored Lua library and API module | [lua.zig](lua.zig) |
| Shared value module, depending only on core | [model.zig](model.zig) |
| Shared-client module imports | [client.zig](client.zig) |
| Embedded asset module | [assets.zig](assets.zig) |

The application and benchmarks intentionally use separate module graphs:
benchmarks retain their optimized dependencies even when the application is
Debug. Packaging and GUI targets share the shipped executable.

`checks.add` registers the source checks and `verify-release`, which depends
on the optimized benchmarks, the install step and `cross`.
