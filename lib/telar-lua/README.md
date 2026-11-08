# telar-lua

The Lua 5.5 interpreter that telar embeds, built from `vendor/lua-5.5.1` in C++
exception mode as `telar-lua-vm`, and the C++ wrappers around it: the bounded VM,
values, JSON conversion and local modules. The wrappers are C++23 with compiled standard module interfaces.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/telar-lua" "${CMAKE_CURRENT_BINARY_DIR}/telar-lua")
target_link_libraries(your_target PRIVATE telar::lua)
```

```cpp
import telar.lua;
```

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure lua` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
