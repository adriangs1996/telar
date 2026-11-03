dev_dir := justfile_directory() / ".dev"
release_dev_dir := dev_dir / "release"
release_build_dir := "out-dev-release"
runtime_dir := justfile_directory() / "services/runtime-cpp"
gui_dir := justfile_directory() / "services/gui-cpp"
renderer_dir := justfile_directory() / "tools/diagram-renderer"
vt_prefix := runtime_dir / "dependencies/install"
runtime := runtime_dir / "out/telar-runtime"
cli := runtime_dir / "out/telar"
# The CLI built beside the runtime it starts, which the GUI and its integration tests find on PATH.
dev_telar := dev_dir / "bin/telar"
gui := gui_dir / "out/telar-gui"
renderer := renderer_dir / "target/release/telar-diagram-renderer"
# On macOS the GUI builds with Homebrew's LLVM, like the runtime; elsewhere with the default compilers.
gui_compilers := if os() == "macos" { '-DCMAKE_C_COMPILER="$(brew --prefix llvm)/bin/clang" -DCMAKE_CXX_COMPILER="$(brew --prefix llvm)/bin/clang++"' } else { "" }

# Show the available commands.
default:
    @just --list

# Build the pinned libghostty-vt that the runtime and the GUI link. Run it once; it needs Zig 0.17.
[working-directory: "services/runtime-cpp"]
vt zig="zig":
    python3 tools/build_ghostty.py --build-dir dependencies/ghostty --prefix dependencies/install --zig "{{ zig }}"

# Build the runtime and the GUI.
build: runtime-build gui-build

# Build the runtime, using out/Debug by default.
[working-directory: "services/runtime-cpp"]
runtime-build directory="out" build_type="Debug": (runtime-configure directory build_type)
    cmake --build "{{ directory }}" --target telar-runtime telar

# Build the GUI, using out/Debug by default.
[working-directory: "services/gui-cpp"]
gui-build directory="out" build_type="Debug": (gui-configure directory build_type)
    cmake --build "{{ directory }}" --target telar-gui telar-gui-command

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
    cmake --build out
    ctest --test-dir out --output-on-failure {{ args }}

# Build and run the GUI tests, the integration ones against the runtime. Extra arguments are passed to CTest.
[working-directory: "services/gui-cpp"]
gui-test *args: dev-bin (gui-configure "out" "Debug" "-DTELAR_GUI_TEST_RUNTIME=" + dev_telar)
    cmake --build out
    ctest --test-dir out --output-on-failure {{ args }}

# Refresh the runtime compilation database and generated headers for clangd.
[working-directory: "services/runtime-cpp"]
runtime-editor: (runtime-configure "out" "Debug")
    cmake --build out --target cell-layout

# Analyze the production runtime sources without applying fixes.
[working-directory: "services/runtime-cpp"]
runtime-lint jobs="2": runtime-editor
    cmake "-DJOBS={{ jobs }}" -P cmake/lint.cmake

# Analyze the GUI sources with its clang-tidy profile.
[working-directory: "services/gui-cpp"]
gui-lint: (gui-configure "out" "Debug")
    cmake --build out --target gui-lint

# Package a Release Telar C++ Preview.app, install it under APPS and link its `telar` into BIN.
[macos]
install-gui apps=(home_directory() / "Applications") bin=(home_directory() / ".local/bin"): renderer (runtime-configure "out-release" "Release") (gui-configure "out-release" "Release")
    #!/usr/bin/env bash
    set -euo pipefail
    stage="{{ dev_dir }}/stage"
    app="Telar C++ Preview.app"
    rm -rf "$stage"
    cmake --build "{{ runtime_dir }}/out-release" --target telar-runtime telar
    cmake --install "{{ runtime_dir }}/out-release" --prefix "$stage"
    install -m 755 "{{ renderer }}" "$stage/bin/telar-diagram-renderer"
    cmake --build "{{ gui_dir }}/out-release" --target telar-gui telar-gui-command
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
    cmake --preset debug
    cmake --build --preset debug
    GTEST_COLOR=yes ctest --preset debug -V "$@"

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

# The runtime targets macOS; Homebrew supplies its compiler and libraries.
[private]
[working-directory: "services/runtime-cpp"]
runtime-configure directory build_type *options:
    cmake -S . -B {{ directory }} -G Ninja -DCMAKE_BUILD_TYPE={{ build_type }} -DCMAKE_CXX_COMPILER="$(brew --prefix llvm)/bin/clang++" -DGHOSTTY_VT_ROOT="{{ vt_prefix }}" -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" -DNGHTTP2_ROOT="$(brew --prefix libnghttp2)" -DBROTLI_ROOT="$(brew --prefix brotli)" -DZSTD_ROOT="$(brew --prefix zstd)" -DPNG_ROOT="$(brew --prefix libpng)" {{ options }}

[private]
[working-directory: "services/gui-cpp"]
gui-configure directory build_type *options:
    cmake -S . -B {{ directory }} -G Ninja -DCMAKE_BUILD_TYPE={{ build_type }} {{ gui_compilers }} -DGHOSTTY_VT_ROOT="{{ vt_prefix }}" -DTELAR_GUI_QT_BUILD_DIR="{{ justfile_directory() }}/.qt-cache" {{ options }}

alias b := build
alias r := run
