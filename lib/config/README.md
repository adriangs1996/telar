# telar-config

Reading and validating telar's Lua configuration: the client sections the GUI
applies and the runtime sections it reports, with the option types they produce
(`agents/`, `proxy/`, `history/`, `graphics/`, `terminal/`). The runtime's
configuration loader stays in `src/runtime/config`. It is C++23 and links
`telar-lua` and `telar-plugins`.

Each process imports only the modules it uses:

- `telar.config.core`: what the three processes share. Limit notices, value
  constraints, agent providers, integration providers and local Lua modules.
- `telar.config.runtime`: the `runtime` section. Agents, proxy, history filters,
  terminal control and `RuntimeValues`.
- `telar.config.client`: the `client` section. Commands, actions, components,
  bindings and the prompt.
- `telar.config.gui`: the `gui` and `theme` sections.
- `telar.config.snapshot`: `SnapshotReader`, which validates a whole configuration
  with the other four.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/config" "${CMAKE_CURRENT_BINARY_DIR}/telar-config")
target_link_libraries(your_target PRIVATE telar::config)
```

```cpp
import telar.config.client;
```

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure config` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
