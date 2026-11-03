# telar-tls

The proxy's certificate authority as both the runtime and the `telar` CLI see
it: OpenSSL handles and allocation, certificate pairs, PEM documents, the
authority directory, and the system trust records `telar proxy trust` installs.
The runtime's TLS sessions and interception stay in `services/runtime-cpp/tls`.
It is header-only C++23 and links OpenSSL 3.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-tls" "${CMAKE_CURRENT_BINARY_DIR}/telar-tls")
target_link_libraries(your_target PRIVATE telar::tls)
```

```cpp
#include "telar_tls/trust/service.hpp"
```

## Editor

`just editor` configures `out/` for clangd: `out/clangd/compile_flags.txt` carries the
include directories and definitions consumers compile these headers with
(`cmake/telar_editor.cmake`). `.clangd-build.json` refreshes it on save.
