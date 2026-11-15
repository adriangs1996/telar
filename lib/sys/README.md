# telar-sys

The operating system's C interface as modules. These are the only module units
that include C system headers: each one includes them in its global module
fragment and exports the names with `using ::open;`, so importers reach POSIX,
socket, process, Apple and Linux declarations through `import` instead of
copying the headers into their own BMIs.

| Module | What it exports |
| --- | --- |
| `telar.sys.posix` | descriptors, files and directories, memory mappings, identity, time, dynamic loading, errnos and the standard streams; `telar::sys::lastError()`, `telar::sys::setLastError()` and `telar::sys::errorName()`, the name telar reports for an errno |
| `telar.sys.socket` | sockets, addresses, name resolution and interfaces |
| `telar.sys.process` | processes, signals, `posix_spawn`, resource limits, terminals and threads |
| `telar.sys.apple` | Darwin only: `libproc`, `sysctl`, kqueue, Mach and the `_np` extensions |
| `telar.sys.linux` | Linux only: epoll, `getrandom`, the kernel calls glibc wraps and musl does not, and `telar::sys::addSpawnCloseFrom()` |

`sys` is the lowest layer: it imports nothing from telar, and `telar-base`,
`telar-platform` and the libraries above them build on it.

Macros do not cross an import, so each module also exports the ones the tree
reads under their own names: constants as `inline constexpr` (`O_CLOEXEC`,
`EINTR`, `POLLIN`) and function-like macros as functions. Those a constant
expression can evaluate stay `constexpr` in the interface (`S_ISREG`,
`CMSG_SPACE`); the rest are declared there and defined in the module's `.cpp`,
which includes the header again and calls the macro (`WIFEXITED`, `CMSG_DATA`,
`EV_SET`). The same spelling works whether or not an importer
also includes the header. `_IOW` and `_IOWR` take a type, so they cross as
templates: `telar::sys::ioctlWrite<Argument>(group, number)` and
`ioctlReadWrite<Argument>`. glibc declares some of them as enumerators behind a
macro of the same name (`SOCK_STREAM`, `IPPROTO_TCP`), which are exported with a
using-declaration instead. `errno` is read through `telar::sys::lastError()` and
set through `telar::sys::setLastError()`, and the struct members a header names
through a macro through accessors such as `telar::sys::signalHandler(action)`.
A name that exists on one platform only lives in `telar.sys.apple` or
`telar.sys.linux`, and code that depends on it checks the platform
(`__APPLE__`, `__linux__`), not the macro. The same goes for the libc: `__GLIBC__`
exists only in a unit that includes a libc header, and importers include none, so
a choice between glibc and musl is made inside `lib/sys` and exported as one name
that works on both.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/sys" "${CMAKE_CURRENT_BINARY_DIR}/telar-sys")
target_link_libraries(your_target PRIVATE telar::sys)
```

```cpp
import telar.sys.posix;
```
