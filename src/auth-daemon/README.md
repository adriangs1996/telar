# Telar auth daemon

Standalone C++23 service scaffold for remote access to system-user runtimes.
The executable currently exits successfully. It does not listen on a port,
authenticate users, change privileges or start runtimes yet.

## Development

From the repository root:

```sh
just auth-build
just auth-test
just lint
just format-check
just format
```

The daemon builds in the repository's single tree, `out/dev` for the dev
preset, whose `compile_commands.json` the root `.clangd` reads and `just
editor` refreshes. `just lint` and the tree's `lint` and `lifetime` targets
cover it with every other registered target; the format and clang-tidy
profiles are shared with the C++ runtime through relative symlinks. TBC is
not a build dependency.

Use `tools/cpp bootstrap` and add `.toolchain/bin` to `PATH`. The presets use
the pinned LLVM 23.1.5 / CMake 4.4.5 / Ninja 1.13.2 toolchain.

## Other trees

`tools/cpp configure sanitize` enables AddressSanitizer and
UndefinedBehaviorSanitizer in `out/sanitize`. The only test currently checks
that the scaffold executable exits successfully:

```sh
tools/cpp configure sanitize
tools/cpp build sanitize -- --target telar-auth-daemon
tools/cpp test sanitize -- -L '^auth$'
```

`TELAR_AUTH_WARNINGS_AS_ERRORS=ON` makes compiler warnings fatal, and
`-DTELAR_BUILD_AUTH=OFF` leaves the daemon out of a tree. Installing a tree
places the executable in `bin/` under the chosen prefix, beside what the
tree's other processes install:

```sh
tools/cpp configure release
tools/cpp build release -- --target telar-auth-daemon
cmake --install out/release --prefix /path/to/staging
```

This installs the executable, not a system service or a privileged helper.
