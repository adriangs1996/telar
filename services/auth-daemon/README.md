# Telar auth daemon

Standalone C++23 service scaffold for remote access to system-user runtimes.
The executable currently exits successfully. It does not listen on a port,
authenticate users, change privileges or start runtimes yet.

## Development

From the repository root:

```sh
just auth-build
just auth-test
just auth-lint
just auth-format-check
just auth-format
```

`just auth-editor` configures `out/compile_commands.json` without building the
runtime or GUI. `just editor` includes this project too. `.clangd` uses that
database, and `.clangd-build.json` refreshes it on save in editors that support it.
The format and clang-tidy profiles are shared with the C++ runtime through
relative symlinks. Tooling targets use the existing generic CMake script in
`dlls/tbc/cmake/tooling.cmake`; TBC is not a build dependency.

Requirements are CMake 3.25 or newer, Ninja and a C++23 compiler. Formatting and
linting additionally require clang-format and clang-tidy, preferably from the
compiler's LLVM installation. The `just` recipes select Homebrew LLVM on macOS
and the default toolchain on Linux, like the GUI recipes.

## Standalone CMake

Run these commands from `services/auth-daemon/`. Select a compiler with `CXX`
on the first configuration or pass `-DCMAKE_CXX_COMPILER=/path/to/clang++`.
The presets do not hardcode a compiler installation.

```sh
cmake --preset debug
cmake --build --preset debug
ctest --preset debug
cmake --build --preset debug --target lint format-check
```

The `release` and `sanitize` presets use `out-release/` and `out-sanitize/`.
`sanitize` enables AddressSanitizer and UndefinedBehaviorSanitizer. The only
test currently checks that the scaffold executable exits successfully.

```sh
cmake --preset sanitize
cmake --build --preset sanitize
ctest --preset sanitize
```

`TELAR_AUTH_WARNINGS_AS_ERRORS=ON` makes compiler warnings fatal.
`BUILD_TESTING=OFF` disables CTest registration. Installation places the
executable in `bin/` under the chosen prefix:

```sh
cmake --install out-release --prefix /path/to/staging
```

This installs the executable only, not a system service or a privileged helper.
