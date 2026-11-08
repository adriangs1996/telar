# websock

C++23 WebSocket library scaffold shared by Telar's server and clients.
There is no WebSocket implementation yet. For now, `telar::websock` is an
compiled module target exposing `includes/*.cppm`, and `main.cpp` checks that the
public module imports. It does not open a connection or test the protocol.

## Development

Use [the pinned C++ workflow](../../docs/build/cpp-modules.md). From the root:

```sh
tools/cpp configure websock
tools/cpp build websock
tools/cpp test websock
```

`.clangd` uses `out/compile_commands.json`; run `.toolchain/bin/clangd` with
`--experimental-modules-support` after building the module interfaces.
`just websock-build`, `websock-test`, `websock-lint` and `websock-format` use the
same toolchain. Bootstrap it before using the standalone CMake presets.

## Standalone CMake

From `lib/websock/`:

```sh
cmake --preset debug
cmake --build --preset debug
ctest --preset debug
cmake --build --preset debug --target lint format-check
```

Select a compiler with `CXX` on the first configuration or pass
`-DCMAKE_CXX_COMPILER=/path/to/clang++`. The presets do not hardcode compiler
installations. `release` builds in `out-release/`; `sanitize` builds in
`out-sanitize/` with AddressSanitizer and UndefinedBehaviorSanitizer.

```sh
cmake --preset sanitize
cmake --build --preset sanitize
ctest --preset sanitize
```

`WEBSOCK_WARNINGS_AS_ERRORS=ON` makes compiler warnings fatal.
`BUILD_TESTING=OFF` disables the standalone smoke test. Development options,
tests and tooling targets are only created when configuring this project on
its own; they do not propagate to consumers using `add_subdirectory`.

## Consume from another CMake project

```cmake
add_subdirectory("${TELAR_ROOT}/lib/websock" "${CMAKE_CURRENT_BINARY_DIR}/websock")
target_link_libraries(your_target PRIVATE telar::websock)
```

The library depends on `telar::base` for the shared allocator contract, without
runtime, GUI, client-protocol, TLS or third-party dependencies. `Server` accepts
a caller-owned allocator satisfying `telar::Allocator`; it does not define a
second allocation interface. The allocator must outlive the server.
Its public include is `<websock/websock.hpp>`.

To install the headers and CMake package:

```sh
cmake --install out-release --prefix /path/to/staging
```

A consumer can then configure with `-DCMAKE_PREFIX_PATH=/path/to/staging` and
use:

```cmake
find_package(websock CONFIG REQUIRED)
target_link_libraries(your_target PRIVATE telar::websock)
```
