# telar-platform

POSIX primitives the runtime and the GUI share: owned file descriptors, private
files and directories, descriptor-relative opening, process environment,
SHA-256 and the runtime's socket paths and server options. It builds a static
library for `file_descriptor.cpp` and `open_directory.c`; everything else is in
headers. `sha256.hpp` uses OpenSSL, which its consumers link.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-platform" "${CMAKE_CURRENT_BINARY_DIR}/telar-platform")
target_link_libraries(your_target PRIVATE telar::platform)
```

```cpp
#include "telar_platform/file_descriptor.hpp"
```
