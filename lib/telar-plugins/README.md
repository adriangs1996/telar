# telar-plugins

Plugin packages as the runtime, the GUI and the `telar` CLI see them: manifests,
capabilities, inspection, copying, installation, the package registry, the
trust store and its updates. The runtime's
plugin workers and traffic hooks stay in `src/runtime-cpp/plugins`. It is
C++23 with compiled standard module interfaces.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/telar-plugins" "${CMAKE_CURRENT_BINARY_DIR}/telar-plugins")
target_link_libraries(your_target PRIVATE telar::plugins)
```

```cpp
import telar.plugins;
```

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure plugins` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
