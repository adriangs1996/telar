dev_dir := justfile_directory() / ".dev"
release_dev_dir := dev_dir / "release"
release_build_dir := "out-dev-release"
runtime_dir := justfile_directory() / "services/runtime-cpp"
gui_dir := justfile_directory() / "services/gui-cpp"
renderer_dir := justfile_directory() / "tools/diagram-renderer"
runtime := runtime_dir / "out/telar-runtime"
cli := runtime_dir / "out/telar"
# The CLI built beside the runtime it starts, which the GUI and its integration tests find on PATH.
dev_telar := dev_dir / "bin/telar"
gui := gui_dir / "out/telar-gui"
renderer := renderer_dir / "target/release/telar-diagram-renderer"
# Optimized app builds never run tests, and each GUI test executable adds a QML import scan to configure.
no_tests := "-DBUILD_TESTING=OFF"
# All C++ projects use the repository-local pinned toolchain.

# Show the available commands.
default:
    @just --list

# Build the pinned libghostty-vt and bootstrap its verified Zig compiler.
[working-directory: "services/runtime-cpp"]
vt:
    "{{ justfile_directory() }}/tools/cpp" vt

# Build the runtime and the GUI.
build: runtime-build gui-build

# Build the runtime, using out/Debug by default.
[working-directory: "services/runtime-cpp"]
runtime-build directory="out" build_type="Debug": (runtime-configure directory build_type if build_type == "Debug" { "" } else { no_tests })
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build "{{ directory }}" --target telar-runtime telar

# Build the GUI, using out/Debug by default.
[working-directory: "services/gui-cpp"]
gui-build directory="out" build_type="Debug": (gui-configure directory build_type if build_type == "Debug" { "" } else { no_tests })
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build "{{ directory }}" --target telar-gui telar-gui-command

# Build the standalone C++ auth daemon without the runtime or GUI dependencies.
[working-directory: "services/auth-daemon"]
auth-build directory="out" build_type="Debug": (auth-configure directory build_type)
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build "{{ directory }}" --target telar-auth-daemon

# Build and run the auth daemon tests. Extra arguments are passed to CTest.
[working-directory: "services/auth-daemon"]
auth-test *args: auth-build
    "{{ justfile_directory() }}/tools/cpp" exec -- ctest --test-dir out --output-on-failure {{ args }}

# Refresh the auth daemon compilation database for clangd.
auth-editor: (auth-configure "out" "Debug")

# Analyze the auth daemon sources without applying fixes.
[working-directory: "services/auth-daemon"]
auth-lint: auth-editor
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out --target lint

# Format the auth daemon sources.
[working-directory: "services/auth-daemon"]
auth-format: auth-editor
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out --target format

# Check the auth daemon formatting without changing sources.
[working-directory: "services/auth-daemon"]
auth-format-check: auth-editor
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out --target format-check

# Build the standalone WebSocket library's compilation smoke test.
[working-directory: "dlls/websock"]
websock-build directory="out" build_type="Debug": (websock-configure directory build_type)
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build "{{ directory }}"

# Run the WebSocket library tests. Extra arguments are passed to CTest.
[working-directory: "dlls/websock"]
websock-test *args: websock-build
    "{{ justfile_directory() }}/tools/cpp" exec -- ctest --test-dir out --output-on-failure {{ args }}

# Refresh the WebSocket library's header flags and compilation database for clangd.
websock-editor: (websock-configure "out" "Debug")

# Analyze the WebSocket library sources without applying fixes.
[working-directory: "dlls/websock"]
websock-lint: websock-editor
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out --target lint

# Format the WebSocket library sources.
[working-directory: "dlls/websock"]
websock-format: websock-editor
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out --target format

# Check the WebSocket library formatting without changing sources.
[working-directory: "dlls/websock"]
websock-format-check: websock-editor
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out --target format-check

# Build the diagram renderer that the macOS bundle ships beside the runtime. It needs Cargo.
renderer:
    cargo build --release --locked --manifest-path "{{ renderer_dir }}/Cargo.toml" --target-dir "{{ renderer_dir }}/target"

# Build everything, start an isolated development runtime and open the GUI on it.
app: dev-bin gui-build (dev-app gui dev_dir)

# Run optimized GUI/runtime builds with development config and their own socket/history.
app-release: (dev-bin release_build_dir "Release" release_dev_dir) (gui-build release_build_dir "Release") (dev-app (gui_dir / release_build_dir / "telar-gui") release_dev_dir)

# Build and run the runtime on the development socket. Extra arguments are passed to it.
run *args: runtime-build
    mkdir -p -m 700 "{{ dev_dir }}"
    TELAR_DEVELOPMENT_CONFIG="{{ justfile_directory() }}/dev/config.lua" TELAR_SOCKET="{{ dev_dir }}/runtime.sock" TELAR_HISTORY="{{ dev_dir }}/history.db" "{{ runtime }}" {{ args }}

# Stop only the Debug development runtime.
stop:
    TELAR_SOCKET="{{ dev_dir }}/runtime.sock" "{{ cli }}" server stop

# Stop only the Release development runtime, including its panes.
stop-release:
    TELAR_SOCKET="{{ release_dev_dir }}/runtime.sock" "{{ runtime_dir }}/{{ release_build_dir }}/telar" server stop

# Build and run the runtime and GUI tests.
test: runtime-test gui-test

# Build and run the runtime tests. Extra arguments are passed to CTest.
[working-directory: "services/runtime-cpp"]
runtime-test *args: (runtime-configure "out" "Debug")
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out
    "{{ justfile_directory() }}/tools/cpp" exec -- ctest --test-dir out --output-on-failure {{ args }}

# Build and run the GUI tests, the integration ones against the runtime. Extra arguments are passed to CTest.
[working-directory: "services/gui-cpp"]
gui-test *args: dev-bin (gui-configure "out" "Debug" "-DTELAR_GUI_TEST_RUNTIME=" + dev_telar)
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out
    "{{ justfile_directory() }}/tools/cpp" exec -- ctest --test-dir out --output-on-failure {{ args }}

# Each project gets out/compile_commands.json and, for a dll, the header flags in
# out/clangd/compile_flags.txt; its .clangd-build.json then refreshes them on save.
# Configure the C++ libraries, CLI and auth daemon for clangd.
editor: runtime-editor
    #!/usr/bin/env bash
    set -euo pipefail
    options=(-G Ninja -DCMAKE_BUILD_TYPE=Debug)
    "{{ justfile_directory() }}/tools/cpp" bootstrap
    export PATH="{{ justfile_directory() }}/.toolchain/bin:$PATH"
    ghostty=$("{{ justfile_directory() }}/tools/cpp" vt | tail -n 1)
    options+=("-DGHOSTTY_VT_ROOT=$ghostty" "-DCMAKE_TOOLCHAIN_FILE={{ justfile_directory() }}/.toolchain/toolchain.cmake")
    for project in dlls/telar-base dlls/telar-client dlls/telar-config dlls/telar-lua dlls/telar-platform dlls/telar-plugins dlls/telar-tls dlls/websock services/cli-cpp services/auth-daemon; do
        cmake -S "$project" -B "$project/out" "${options[@]}" >/dev/null
        echo "configured $project/out"
    done

# Refresh the runtime compilation database and generated headers for clangd.
[working-directory: "services/runtime-cpp"]
runtime-editor: (runtime-configure "out" "Debug")
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out --target cell-layout

# Analyze the production runtime sources without applying fixes.
[working-directory: "services/runtime-cpp"]
runtime-lint jobs="2" directory="out": (runtime-configure directory "Debug")
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake "-DJOBS={{ jobs }}" "-DRUNTIME_BUILD_DIRECTORY={{ directory }}" -P cmake/lint.cmake

# Analyze the GUI sources with its clang-tidy profile.
[working-directory: "services/gui-cpp"]
gui-lint: (gui-configure "out" "Debug")
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build out --target gui-lint

# Package a Release Telar C++ Preview.app, install it under APPS and link its `telar` into BIN.
[macos]
install-gui apps=(home_directory() / "Applications") bin=(home_directory() / ".local/bin"): renderer (runtime-configure "out-release" "Release" no_tests) (gui-configure "out-release" "Release" no_tests)
    #!/usr/bin/env bash
    set -euo pipefail
    stage="{{ dev_dir }}/stage"
    app="Telar C++ Preview.app"
    rm -rf "$stage"
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build "{{ runtime_dir }}/out-release" --target telar-runtime telar
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --install "{{ runtime_dir }}/out-release" --prefix "$stage"
    install -m 755 "{{ renderer }}" "$stage/bin/telar-diagram-renderer"
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build "{{ gui_dir }}/out-release" --target telar-gui telar-gui-command
    python3 "{{ gui_dir }}/tools/package_macos.py" --build "{{ gui_dir }}/out-release" --runtime-prefix "$stage" --output "$stage/$app"
    mkdir -p "{{ apps }}" "{{ bin }}"
    rm -rf "{{ apps }}/$app"
    cp -R "$stage/$app" "{{ apps }}/$app"
    ln -sf "{{ apps }}/$app/Contents/Resources/bin/telar" "{{ bin }}/telar"

# Run the Go proxy service. Extra arguments are passed to the service.
[working-directory: "services/proxy"]
proxy *args:
    go run ./cmd/telar-proxy {{ args }}

# Test the Go proxy module. Extra arguments are passed to `go test`.
[working-directory: "services/proxy"]
proxy-test *args:
    go test {{ args }} ./...

# Validate Linux TUN forwarding and NAT in an isolated Docker network.
proxy-test-linux:
    python3 services/proxy/tests/linux/run.py

# Build EBNF and run tests with color. Extra arguments are forwarded to CTest.
[positional-arguments]
[working-directory: "dlls/ebnf"]
ebnf-test *args:
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --preset debug
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake --build --preset debug
    GTEST_COLOR=yes "{{ justfile_directory() }}/tools/cpp" exec -- ctest --preset debug -V "$@"

[private]
dev-bin directory="out" build_type="Debug" state_dir=dev_dir: (runtime-build directory build_type)
    mkdir -p -m 700 "{{ state_dir }}" "{{ state_dir }}/bin"
    ln -sf "{{ runtime_dir }}/{{ directory }}/telar" "{{ state_dir }}/bin/telar"

[private]
dev-app binary state_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="{{ state_dir }}/bin:$PATH" TELAR_SOCKET="{{ state_dir }}/runtime.sock" TELAR_HISTORY="{{ state_dir }}/history.db"
    export TELAR_BIN_PATH="{{ state_dir }}/bin/telar" TELAR_SOCKET_PATH="$TELAR_SOCKET"
    export TELAR_DEVELOPMENT_CONFIG="{{ justfile_directory() }}/dev/config.lua"
    "{{ state_dir }}/bin/telar" server endpoint > /dev/null
    exec "{{ binary }}"

# Both platforms use the verified repository-local compiler and managed libraries.
[private]
[working-directory: "services/runtime-cpp"]
runtime-configure directory build_type *options:
    "{{ justfile_directory() }}/tools/cpp" configure runtime -B "{{ directory }}" --config {{ build_type }} -- {{ options }}

[private]
[working-directory: "dlls/websock"]
websock-configure directory build_type *options:
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake -S . -B "{{ directory }}" -G Ninja -DCMAKE_BUILD_TYPE={{ build_type }} -DCMAKE_TOOLCHAIN_FILE="{{ justfile_directory() }}/.toolchain/toolchain.cmake" {{ options }}

[private]
[working-directory: "services/auth-daemon"]
auth-configure directory build_type *options:
    "{{ justfile_directory() }}/tools/cpp" exec -- cmake -S . -B "{{ directory }}" -G Ninja -DCMAKE_BUILD_TYPE={{ build_type }} -DCMAKE_TOOLCHAIN_FILE="{{ justfile_directory() }}/.toolchain/toolchain.cmake" {{ options }}

[private]
[working-directory: "services/gui-cpp"]
gui-configure directory build_type *options:
    "{{ justfile_directory() }}/tools/cpp" configure gui -B "{{ directory }}" --config {{ build_type }} -- -DTELAR_GUI_QT_BUILD_DIR="{{ justfile_directory() }}/.qt-cache" {{ options }}

alias b := build
alias r := run
