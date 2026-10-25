dev_runtime_dir := justfile_directory() / ".zig-out/dev"
desktop_runtime_dir := justfile_directory() / ".zig-out/desktop-dev"
desktop_fresh_dir := justfile_directory() / ".zig-out/desktop"
native_desktop_fresh_dir := justfile_directory() / ".zig-out/native-desktop"

# Show the available commands.
default:
    @just --list

# Build Telar. Extra arguments are forwarded to `zig build`.
build *args:
    zig build {{ args }}

# Build an optimized Telar binary at `.zig-out/prod/bin/telar`.
release:
    zig build --prefix .zig-out/prod -Doptimize=ReleaseFast

# Build the GUI in ReleaseFast and install it for this user: Telar.app under
# ~/Applications and `telar` symlinked into ~/.local/bin, so Finder, shells and
# the agent hooks all find the same executable.
[macos]
install-gui apps=(home_directory() / "Applications") bin=(home_directory() / ".local/bin"):
    zig build bundle -Doptimize=ReleaseFast
    mkdir -p "{{ apps }}" "{{ bin }}"
    rm -rf "{{ apps }}/Telar.app"
    cp -R zig-out/Telar.app "{{ apps }}/Telar.app"
    "{{ apps }}/Telar.app/Contents/Resources/bin/telar" cli install --dir "{{ bin }}"

# Build the GUI in ReleaseFast and install it for this user: `bin/telar`, the
# desktop entry and the icon under the prefix.
[linux]
install-gui prefix=(home_directory() / ".local"):
    zig build --prefix "{{ prefix }}" -Doptimize=ReleaseFast

# Stop only the development runtime.
stop:
    TELAR_SOCKET="{{ dev_runtime_dir }}/runtime.sock" zig build run -- server stop

app:
    mkdir -p -m 700 "{{ dev_runtime_dir }}"
    TELAR_SOCKET="{{ dev_runtime_dir }}/runtime.sock" TELAR_HISTORY="{{ dev_runtime_dir }}/history.db" zig build run -- gui

# Build and run Desktop with dev/desktop.lua and a fresh Zig runtime, or on SOCKET.
desktop socket="": (_desktop socket "zig")

# Build and run Desktop with dev/desktop.lua and a fresh C++ runtime, or on SOCKET.
native-desktop socket="": (_desktop socket "cpp")

# Without a socket, reset the runtime and its saved layout, then stop it on exit.
[private]
[working-directory: "services/desktop-mode"]
_desktop socket implementation:
    #!/usr/bin/env bash
    set -euo pipefail
    cmake --preset debug
    cmake --build --preset debug --target telar-desktop
    export TELAR_DESKTOP_CONFIG="{{ justfile_directory() }}/dev/desktop.lua"
    export TELAR_DESKTOP_UI_DIR="${TELAR_DESKTOP_UI_DIR:-$PWD/ui}"
    export TELAR_DESKTOP_ASSETS_DIR="${TELAR_DESKTOP_ASSETS_DIR:-$PWD/assets}"
    socket="{{ socket }}"
    if [[ -n "$socket" ]]; then
        exec ./out/debug/telar-desktop "$socket"
    fi

    runtime="{{ desktop_fresh_dir }}"
    if [[ "{{ implementation }}" == cpp ]]; then
        cmake -S ../runtime-cpp -B ../runtime-cpp/out
        cmake --build ../runtime-cpp/out --target telar-runtime
        telar="{{ justfile_directory() }}/services/runtime-cpp/out/telar-runtime"
        runtime="{{ native_desktop_fresh_dir }}"
    else
        (cd "{{ justfile_directory() }}" && zig build)
        telar="{{ justfile_directory() }}/zig-out/bin/telar"
    fi

    export TELAR_SOCKET="$runtime/runtime.sock"
    export TELAR_HISTORY="$runtime/history.db"
    # A run that was killed leaves its runtime behind; it must stop before its files go.
    "$telar" server stop >/dev/null
    for _ in {1..50}; do
        [[ -S "$TELAR_SOCKET" ]] || break
        sleep 0.1
    done
    if [[ -S "$TELAR_SOCKET" ]]; then
        echo "The previous desktop runtime did not stop: $TELAR_SOCKET" >&2
        exit 1
    fi

    rm -rf "$runtime"
    mkdir -p -m 700 "$runtime"
    # The desktop saves the workbench layout per runtime socket, named by its SHA-256.
    state="${TELAR_DESKTOP_STATE_DIR:-$HOME/Library/Application Support/telar/desktop}"
    layout="workbench-$(printf '%s' "$TELAR_SOCKET" | shasum -a 256 | cut -d ' ' -f 1).json"
    rm -f "$state/$layout"
    trap '"$telar" server stop >/dev/null' EXIT
    "$telar" server endpoint >/dev/null
    ./out/debug/telar-desktop "$TELAR_SOCKET"

# Seed a separate desktop runtime once, using a checkpoint and the socket of its source runtime.
desktop-runtime $source="" $session="":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p -m 700 "{{ desktop_runtime_dir }}"
    set --
    if [[ -n "$source" || -n "$session" ]]; then
        set -- --clone-from "$source" --clone-session "$session"
    elif [[ ! -f "{{ desktop_runtime_dir }}/runtime.sock.desktop-clone.json" || ! -f "{{ desktop_runtime_dir }}/session.ckpt" ]]; then
        echo 'First use: just desktop-runtime SOURCE_SOCKET SOURCE_CHECKPOINT' >&2
        exit 1
    fi
    export TELAR_SOCKET="{{ desktop_runtime_dir }}/runtime.sock"
    export TELAR_HISTORY="{{ desktop_runtime_dir }}/history.db"
    exec zig build run -- server --no-config "$@"

# Run Desktop against the cloned runtime started by desktop-runtime.
desktop-dev:
    just desktop "{{ desktop_runtime_dir }}/runtime.sock"

# Check the desktop modules and development programs and generate the clangd compilation database.
[working-directory: "services/desktop-mode"]
desktop-check:
    cmake --preset debug
    cmake --build --preset debug --target desktop-editor

# Refresh desktop modules and development programs for clangd without building main.cpp.
[working-directory: "services/desktop-mode"]
desktop-editor:
    cmake --preset debug
    cmake --build --preset debug --target desktop-editor

# Refresh the C++ runtime compilation database and generated headers for clangd.
[working-directory: "services/runtime-cpp"]
runtime-editor:
    cmake -S . -B out
    cmake --build out --target cell-layout

# Analyze the production C++ runtime sources without applying fixes.
[working-directory: "services/runtime-cpp"]
runtime-lint jobs="2": runtime-editor
    cmake "-DJOBS={{ jobs }}" -P cmake/lint.cmake

# Format the desktop C++, Objective-C++ and Lua sources with their project rules.
[working-directory: "services/desktop-mode"]
desktop-fmt:
    cmake -P cmake/format.cmake

# Check desktop formatting without changing files.
[working-directory: "services/desktop-mode"]
desktop-fmt-check:
    cmake -DCHECK=ON -P cmake/format.cmake

# Build and run a program from services/desktop-mode/debug by its filename stem.
[working-directory: "services/desktop-mode"]
desktop-debug program *args:
    cmake --preset debug
    cmake --build --preset debug --target "{{ program }}"
    "./out/debug/{{ program }}" {{ args }}

# Build and run an isolated development runtime. Extra arguments are passed to Telar.
run *args:
    mkdir -p -m 700 "{{ dev_runtime_dir }}"
    TELAR_SOCKET="{{ dev_runtime_dir }}/runtime.sock" TELAR_HISTORY="{{ dev_runtime_dir }}/history.db" zig build run -- {{ args }}

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

# Format the project Zig sources.
fmt:
    zig fmt build.zig build.zig.zon src examples benchmarks linters

# Check formatting without changing files.
fmt-check:
    zig fmt --check build.zig build.zig.zon src examples benchmarks linters

# Check code style. Extra arguments are passed to codestyle.
codestyle *args:
    zig build codestyle -- {{ args }}

# Apply safe code style fixes. Extra arguments are passed to codestyle.
codestyle-fix *args:
    zig build codestyle -- --fix {{ args }}

# Apply safe fixes, then run formatting and source checks.
check:
    just codestyle-fix
    just fmt-check
    zig build check

# Run benchmarks. Extra arguments are passed to the benchmark executable.
bench *args:
    zig build bench -- {{ args }}

# List benchmark names.
bench-list:
    zig build bench -- --list

# Type-check platform-specific code for supported cross targets.
cross:
    zig build cross

# Run portability and performance release gates.
verify-release:
    zig build verify-release

alias b := build
alias r := run
