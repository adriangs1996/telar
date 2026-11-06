# telar-client

The client side of the runtime protocol: wire framing, message codecs and
serializers, and `telar::Client`, which talks to a runtime over its Unix socket.
It is C++23 with compiled standard module interfaces and depends on `telar::base`, the standard library and
POSIX sockets. The base library does not depend on this protocol. `RequestError`
lives here because it carries a protocol-specific `FailureCode`.
`services/gui-cpp` and the runtime CLI in `services/runtime-cpp` use it.

```cmake
add_subdirectory("${TELAR_ROOT}/dlls/telar-client" "${CMAKE_CURRENT_BINARY_DIR}/telar-client")
target_link_libraries(your_target PRIVATE telar::client)
```

```cpp
import telar.client;
```

`telar.client.telar` re-exports the client interfaces; import individual modules
under `telar.client.codecs` or `telar.client.serializers` to use a narrower graph.

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure client` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
