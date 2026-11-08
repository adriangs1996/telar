# telar-platform

POSIX primitives the runtime, the GUI and the `telar` CLI share: owned file
descriptors, private files and directories, descriptor-relative opening, process
environment, SHA-256, child processes on pipes and ptys, git checkout files,
executable paths, debug tracing, and the runtime's socket paths, server options
and background launch. It builds a static library for the sources in `src/`;
everything else is in headers. `sha256.hpp` uses OpenSSL, which its consumers link.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/telar-platform" "${CMAKE_CURRENT_BINARY_DIR}/telar-platform")
target_link_libraries(your_target PRIVATE telar::platform)
```

```cpp
#include "telar_platform/file_descriptor.hpp"
```

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure platform` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
