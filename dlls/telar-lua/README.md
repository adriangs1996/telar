# telar-lua

The Lua 5.5 interpreter that telar embeds, built from `vendor/lua-5.5.1` in C++
exception mode as `telar-lua-vm`, and the C++ wrappers around it: the bounded VM,
values, JSON conversion and local modules. The wrappers are header-only C++23.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-lua" "${CMAKE_CURRENT_BINARY_DIR}/telar-lua")
target_link_libraries(your_target PRIVATE telar::lua)
```

```cpp
#include "telar_lua/vm.hpp"
```

## Editor

`just editor` configures `out/` for clangd: `out/clangd/compile_flags.txt` carries the
include directories and definitions consumers compile these headers with
(`cmake/telar_editor.cmake`). `.clangd-build.json` refreshes it on save.
