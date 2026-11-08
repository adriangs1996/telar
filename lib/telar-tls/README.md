# telar-tls

The proxy's certificate authority as both the runtime and the `telar` CLI see
it: OpenSSL handles and allocation, certificate pairs, PEM documents, the
authority directory, and the system trust records `telar proxy trust` installs.
The runtime's TLS sessions and interception stay in `src/runtime-cpp/tls`.
It is C++23 with compiled standard module interfaces and links OpenSSL 3.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/telar-tls" "${CMAKE_CURRENT_BINARY_DIR}/telar-tls")
target_link_libraries(your_target PRIVATE telar::tls)
```

```cpp
import telar.tls;
```

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure tls` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
