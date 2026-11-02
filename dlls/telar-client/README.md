# telar-client

The client side of the runtime protocol: wire framing, message codecs and
serializers, and `telar::Client`, which talks to a runtime over its Unix socket.
It is header-only C++23 and depends on the standard library and POSIX sockets.
`services/gui-cpp` and the runtime CLI in `services/runtime-cpp` use it.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-client" "${CMAKE_CURRENT_BINARY_DIR}/telar-client")
target_link_libraries(your_target PRIVATE telar::client)
```

```cpp
#include "telar_client/telar.hpp"
```

`telar.hpp` includes every header; include `telar_client/codecs/...` or
`telar_client/serializers/...` directly to pull in less.
