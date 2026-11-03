# telar-plugins

Plugin packages as both processes see them: manifests, capabilities,
inspection, copying, the package registry and the trust store. The runtime's
plugin workers and traffic hooks stay in `services/runtime-cpp/plugins`. It is
header-only C++23.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-plugins" "${CMAKE_CURRENT_BINARY_DIR}/telar-plugins")
target_link_libraries(your_target PRIVATE telar::plugins)
```

```cpp
#include "telar_plugins/package_inspection.hpp"
```
