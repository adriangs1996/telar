# Build navigation

`build.zig` is the assembly index. It creates the application, registers the
optional targets, attaches the GUI and connects cross-platform checks to the
parallel-test barrier. Source paths are always resolved from the repository
root through `b.path`, even from these support files.

| Change | File |
| --- | --- |
| Shipped module graph, dependencies, build options, default install and `run` | [Application.zig](Application.zig) |
| Shared resolved modules and consistent test-suite imports | [Modules.zig](Modules.zig) |
| Optimized benchmark graph, `bench`, `echo-probe`, browser verification | [Benchmarks.zig](Benchmarks.zig) |
| Native GUI modules, `gui`, GUI tests | [gui.zig](gui.zig) |
| macOS adapter sources, Objective-C flags and frameworks shared by app and window test | [macos_gui.zig](macos_gui.zig) |
| Wayland protocol generation, Vulkan sources/libraries, GLSL compilation and embedded SPIR-V | [linux_gui.zig](linux_gui.zig) |
| macOS bundle/DMG and Linux desktop/archive packaging | [packaging.zig](packaging.zig) |
| Test-suite list, `check`, code style, boundaries and release gates | [tests.zig](tests.zig) |
| Windows and Linux portability checks | [cross.zig](cross.zig) |
| Frontend execution experiments | [experiments.zig](experiments.zig) |
| FreeType/HarfBuzz sources and flags | [freetype.zig](freetype.zig) |
| Vendored Lua library and API module | [lua.zig](lua.zig) |
| Shared-client module imports | [client.zig](client.zig) |
| Embedded asset module | [assets.zig](assets.zig) |
| Coverage instrumentation and native coverage flags | [Coverage.zig](Coverage.zig), [c_flags.zig](c_flags.zig) |

The application and benchmarks intentionally use separate module graphs:
benchmarks retain their optimized dependencies even when the application is
Debug. Packaging and GUI targets share the shipped executable.

`tests.add` returns the barrier for parallel prerequisites. The entrypoint
connects `cross.add` to that barrier. Isolated PTY/process/socket test runs keep
their own prerequisite barriers, so scoped test steps do not accidentally run
all suites or start resource-sensitive tests ahead of their prerequisites.

To add a test suite, edit the `suites` array in `tests.zig`. To add an import
available to every suite, update `Modules.addSuiteTest`. Keep execution and
analysis-only suites wired through that same method.
