dev_runtime_dir := justfile_directory() / ".zig-out/dev"

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

# Build and run the C++ desktop client against an existing runtime in Debug mode.
[working-directory: "services/desktop-mode"]
desktop socket=(dev_runtime_dir / "runtime.sock"):
    cmake --preset debug
    cmake --build --preset debug --target telar-desktop
    TELAR_DESKTOP_UI_DIR="${TELAR_DESKTOP_UI_DIR:-$PWD/ui}" ./out/debug/telar-desktop "{{ socket }}"

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
