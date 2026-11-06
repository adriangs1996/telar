# telar-base

The foundations the runtime, the GUI and the `telar` CLI share: UTF-8, ASCII,
JSON and other text codecs (`text/`), allocators, sensitive buffers and
fixed-capacity containers (`memory/`), the diagnostics switches and timing
(`diagnostics/`), the editor kinds (`editors/`), the history search policy
(`history/`), and the program name and version children see (`program_identity.hpp`).
It is header-only C++23, with no dependency on the client protocol or runtime.
Allocators and their adapters live in the neutral `telar` namespace. The caller
owns their lifetime; consumers inject them by reference.

`JsonError` reports malformed JSON without a protocol failure code. Protocol
boundaries translate it to `FailureCode::invalid_request`; `RequestError` lives
in `telar-client`. `LimitReach` is shared data owned by this library and serialized
by the client protocol.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-base" "${CMAKE_CURRENT_BINARY_DIR}/telar-base")
target_link_libraries(your_target PRIVATE telar::base)
```

```cpp
#include "telar_base/text/utf8.hpp"
#include "telar_base/memory/allocator.hpp"
```

## Standalone checks

```sh
cmake -S dlls/telar-base -B dlls/telar-base/out -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build dlls/telar-base/out
ctest --test-dir dlls/telar-base/out --output-on-failure
```

The standalone build compiles every public header separately, with only the
base include directory available. Regression tests cover allocator injection,
budgets, retained bytes, limits and JSON errors without loading the client
protocol. Headers and the `telar::base` CMake target can also be installed with
`cmake --install` and consumed with `find_package(telar-base CONFIG REQUIRED)`.

## Editor

`just editor` configures `out/` for clangd: `out/clangd/compile_flags.txt` carries the
include directories and definitions consumers compile these headers with
(`cmake/telar_editor.cmake`). `.clangd-build.json` refreshes it on save.
