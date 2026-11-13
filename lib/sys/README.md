# telar-sys

The operating system's C interface as modules. These are the only module units
that include C system headers: each one includes them in its global module
fragment and exports the names with `using ::open;`, so importers reach POSIX,
socket, process, Apple and Linux declarations through `import` instead of
copying the headers into their own BMIs.

| Module | What it exports |
| --- | --- |
| `telar.sys.posix` | descriptors, files and directories, memory mappings, identity, time, dynamic loading |
| `telar.sys.socket` | sockets, addresses, name resolution and interfaces |
| `telar.sys.process` | processes, signals, `posix_spawn`, resource limits, terminals and threads |
| `telar.sys.apple` | Darwin only: `libproc`, `sysctl`, kqueue, Mach and the `_np` extensions |
| `telar.sys.linux` | Linux only: epoll, `getrandom` and the glibc extensions |

`sys` is the lowest layer: it imports nothing from telar, and `telar-platform`
builds on it. Macros (`O_CLOEXEC`, `WIFEXITED`, `errno`) are not exported yet;
importers that need them still include the header.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/sys" "${CMAKE_CURRENT_BINARY_DIR}/telar-sys")
target_link_libraries(your_target PRIVATE telar::sys)
```

```cpp
import telar.sys.posix;
```
