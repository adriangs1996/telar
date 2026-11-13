# telar-platform

POSIX primitives the runtime, the GUI and the `telar` CLI share, one module per
family:

| Module | What it holds |
| --- | --- |
| `telar.platform.error` | `SystemError` and the names the CLI prints for an errno |
| `telar.platform.process` | `Command`, `CommandOutput`, `PipeProcess`, `PtyProcess`, `SpawnOptions`, executable paths and the login shell |
| `telar.platform.thread` | starting, naming and identifying threads |
| `telar.platform.fs` | private files and directories, descriptor-relative opening, bounded reads, atomic writes and temporary directories |
| `telar.platform.paths` | the process environment, XDG directories, the runtime's socket and storage paths and its server options |
| `telar.platform.daemon` | the runtime's background launch |
| `telar.platform.events` | observation timestamps and deadlines |
| `telar.platform.net` | nonblocking byte streams, socket addresses and options, peer credentials and `SocketStream` |
| `telar.platform.sha256` | SHA-256 on OpenSSL, which its consumers link |
| `telar.platform.graphics` | shared memory for images handed to the GUI |
| `telar.platform.primitives` | the owner of the textual headers: owned descriptors, mapped regions, random bytes and debug tracing |

`telar.platform` imports every family. Import the family a file uses instead. Git checkout files and hardened git
commands live in `telar.git.checkout`, in `lib/git/checkout`.

It builds a static library for the sources in `src/` and the implementation units
beside each family's interface.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/platform" "${CMAKE_CURRENT_BINARY_DIR}/telar-platform")
target_link_libraries(your_target PRIVATE telar::platform)
```

```cpp
#include "telar_platform/file_descriptor.hpp"
```

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure platform` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`. Module interfaces have their own compile
commands; the remaining native ABI and macro headers borrow consumer commands.
