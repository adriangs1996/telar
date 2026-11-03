# telar-plugins

Plugin packages as the runtime, the GUI and the `telar` CLI see them: manifests,
capabilities, inspection, copying, installation, the package registry, the
trust store and its updates. The runtime's
plugin workers and traffic hooks stay in `services/runtime-cpp/plugins`. It is
header-only C++23.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-plugins" "${CMAKE_CURRENT_BINARY_DIR}/telar-plugins")
target_link_libraries(your_target PRIVATE telar::plugins)
```

```cpp
#include "telar_plugins/package_inspection.hpp"
```
