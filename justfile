dev_runtime_dir := justfile_directory() / ".zig-out/dev"

fuzz_targets := "test-handshake test-fuzz-ipc-client test-fuzz-ipc-server test-fuzz-frames-body test-fuzz-frames-cells test-fuzz-frames-metadata test-fuzz-imaging-png test-fuzz-imaging-ico test-fuzz-http1-head test-fuzz-http1-body test-fuzz-http2-reader test-fuzz-http2-observer"

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

# Build and run an isolated development runtime. Extra arguments are passed to Telar.
run *args:
    mkdir -p -m 700 "{{ dev_runtime_dir }}"
    TELAR_SOCKET="{{ dev_runtime_dir }}/runtime.sock" TELAR_HISTORY="{{ dev_runtime_dir }}/history.db" zig build run -- {{ args }}

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

# Apply safe fixes, then run formatting checks and the complete test suite.
check:
    just codestyle-fix
    just fmt-check
    just test

# Run the complete test suite. Extra arguments are forwarded to `zig build`.
test *args:
    zig build test {{ args }}

# Run the native tests with zcov and write coverage.lcov.
coverage *args:
    tools/coverage.sh {{ args }}

# Run all fuzz roots' tests and replay their corpora, without fuzzing.
fuzz-check:
    zig build {{ fuzz_targets }} -Dgui=false -j1

# Fuzz every target sequentially, e.g. `just fuzz 1M`.
fuzz runs="10K":
    #!/usr/bin/env sh
    set -eu
    log=$(mktemp)
    trap 'rm -f "$log"' EXIT
    for target in {{ fuzz_targets }}; do
        printf '\n== %s ==\n' "$target"
        status=0
        zig build "$target" -Dgui=false -j1 --fuzz={{ quote(runs) }} >"$log" 2>&1 || status=$?
        cat "$log"
        if [ "$status" -ne 0 ]; then
            exit "$status"
        fi
        if grep -Eq 'input saved|panic:|terminated with signal' "$log"; then
            exit 1
        fi
    done

# Run the shared client's tests: its own, over a real socket, and headless.
test-client:
    zig build test-client test-client-integration test-headless

# Run transport tests.
test-transport:
    zig build test-transport

# Run protocol schema tests.
test-schema:
    zig build test-schema

# Run the runtime proxy tests.
test-backend-proxy:
    zig build test-backend-proxy

# Run benchmarks. Extra arguments are passed to the benchmark executable.
bench *args:
    zig build bench -- {{ args }}

# List benchmark names.
bench-list:
    zig build bench -- --list

# Type-check platform-specific code for supported cross targets.
cross:
    zig build cross

# Run correctness, portability and performance release gates.
verify-release:
    zig build verify-release

alias b := build
alias r := run
alias t := test
