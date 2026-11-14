# telar-base

The foundations the runtime, the GUI and the `telar` CLI share: UTF-8 (`text/utf8/`),
JSON (`text/json/`), ASCII and other text codecs (`text/`), each imported on its
own (`telar.base.text.utf8`, `telar.base.text.json`, `telar.base.text`),
allocators (`memory/allocators/`), sensitive buffers (`memory/sensitive/`) and
fixed-capacity containers (`memory/containers/`), which `telar.base.memory` still
re-exports together, the diagnostics switches and timing (`diagnostics/`), the editor kinds (`editors/`), the history search policy
(`history/`), and the program name and version children see (`program_identity.hpp`).
It is C++23 with compiled standard module interfaces, with no dependency on the client protocol or runtime.
Allocators and their adapters live in the neutral `telar` namespace. The caller
owns their lifetime; consumers inject them by reference. `Memory` is the
type-erased allocator a service can take instead of a template parameter:
`MemoryAdapter<A>` puts any `Allocator` behind it, as `ConcurrentMemory` when `A`
is thread safe and as `ErasingMemory` when `A` erases what it releases.
`allocator.hpp` declares them too, so Qt and Objective-C++ code can name them.

`JsonError` reports malformed JSON without a protocol failure code. Protocol
boundaries translate it to `FailureCode::invalid_request`; `RequestError` lives
in `telar-client`. `LimitReach` is shared data owned by this library and serialized
by the client protocol.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/base" "${CMAKE_CURRENT_BINARY_DIR}/telar-base")
target_link_libraries(your_target PRIVATE telar::base)
```

```cpp
#include "telar_base/memory/allocator.hpp" // Native allocator ABI
import telar.base.text.json;
import telar.base.memory.allocators;
import telar.base.diagnostics;
```

## Standalone checks

```sh
tools/cpp configure base
tools/cpp build base
tools/cpp test base
```

The standalone build compiles every module interface and each remaining ABI header separately, with only the
base include directory available. Regression tests cover allocator injection,
budgets, retained bytes, limits and JSON errors without loading the client
protocol. Module sources, residual headers and the `telar::base` CMake target can also be installed with
`cmake --install` and consumed with `find_package(telar-base CONFIG REQUIRED)`.

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure base` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
