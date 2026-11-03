# telar-base

The foundations the runtime, the GUI and the `telar` CLI share: UTF-8, ASCII,
JSON and other text codecs (`text/`), allocators, sensitive buffers and
fixed-capacity containers (`memory/`), the diagnostics switches and timing
(`diagnostics/`), the editor kinds (`editors/`), the history search policy
(`history/`), the program name and version children see (`program_identity.hpp`),
and `RequestError`, which carries a protocol failure code. It is header-only C++23
and depends on `telar-client` for the protocol's failure codes.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-base" "${CMAKE_CURRENT_BINARY_DIR}/telar-base")
target_link_libraries(your_target PRIVATE telar::base)
```

```cpp
#include "telar_base/text/utf8.hpp"
#include "telar_base/memory/allocator.hpp"
```
