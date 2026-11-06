# telar-config

Reading and validating telar's Lua configuration: the client sections the GUI
applies and the runtime sections it reports, with the option types they produce
(`agents/`, `proxy/`, `history/`, `graphics/`, `terminal/`). The runtime's
configuration loader stays in `services/runtime-cpp/config`. It uses the compiled `telar.config` module
C++23 and links `telar-lua` and `telar-plugins`.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-config" "${CMAKE_CURRENT_BINARY_DIR}/telar-config")
target_link_libraries(your_target PRIVATE telar::config)
```

```cpp
import telar.config;
```

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure config` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
