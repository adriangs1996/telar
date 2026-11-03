# telar-platform

POSIX primitives the runtime, the GUI and the `telar` CLI share: owned file
descriptors, private files and directories, descriptor-relative opening, process
environment, SHA-256, child processes on pipes and ptys, git checkout files,
executable paths, debug tracing, and the runtime's socket paths, server options
and background launch. It builds a static library for the sources in `src/`;
everything else is in headers. `sha256.hpp` uses OpenSSL, which its consumers link.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-platform" "${CMAKE_CURRENT_BINARY_DIR}/telar-platform")
target_link_libraries(your_target PRIVATE telar::platform)
```

```cpp
#include "telar_platform/file_descriptor.hpp"
```

## Editor

`just editor` configures `out/` for clangd: `out/clangd/compile_flags.txt` carries the
include directories and definitions consumers compile these headers with
(`cmake/telar_editor.cmake`). `.clangd-build.json` refreshes it on save.
