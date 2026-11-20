# telar-client

The client side of the runtime protocol: the handshake, the framing and
`telar::Client`, which talks to a runtime over its Unix socket. The messages
and their codecs are in `lib/wire`. It is C++23 with compiled standard module
interfaces and depends on `telar::base`, `telar::wire`, the standard library and
POSIX sockets. The base library does not depend on this protocol.
`src/cli` and `src/gui` use it, and the runtime reads the handshake from it.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/client" "${CMAKE_CURRENT_BINARY_DIR}/telar-client")
target_link_libraries(your_target PRIVATE telar::client)
```

```cpp
import telar.client;
```

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure` generates the repository's `out/dev/compile_commands.json`, which covers this library.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
