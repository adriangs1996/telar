# telar-config

Reading and validating telar's Lua configuration: the client sections the GUI
applies and the runtime sections it reports, with the option types they produce
(`agents/`, `proxy/`, `history/`, `graphics/`, `terminal/`). The runtime's
configuration loader stays in `services/runtime-cpp/config`. It is header-only
C++23 and links `telar-lua` and `telar-plugins`.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-config" "${CMAKE_CURRENT_BINARY_DIR}/telar-config")
target_link_libraries(your_target PRIVATE telar::config)
```

```cpp
#include "telar_config/runtime_values.hpp"
```
