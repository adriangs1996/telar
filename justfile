dev_dir := justfile_directory() / ".dev"
release_dev_dir := dev_dir / "release"
cpp := justfile_directory() / "tools/cpp"
# The tree of each preset of CMakePresets.json; a process's programs are in its directory.
build_dir := justfile_directory() / "out"
renderer_dir := justfile_directory() / "tools/diagram-renderer"
runtime := build_dir / "dev/src/runtime/telar-runtime"
cli := build_dir / "dev/src/runtime/telar"
# The CLI built beside the runtime it starts, which the GUI and its integration tests find on PATH.
dev_telar := dev_dir / "bin/telar"
gui := build_dir / "dev/src/gui/telar-gui"
renderer := renderer_dir / "target/release/telar-diagram-renderer"
# The GUI's integration tests run against the development CLI.
test_options := "-DTELAR_GUI_TEST_RUNTIME=" + dev_telar
# All C++ projects use the repository-local pinned toolchain.

# Show the available commands.
default:
    @just --list

# Build the pinned libghostty-vt and bootstrap its verified Zig compiler.
vt:
    "{{ cpp }}" vt

# Build the runtime and the GUI.
build: runtime-build gui-build

# Build the runtime, its CLI and the gateway in the tree of PRESET.
runtime-build preset="dev": (configure preset)
    "{{ cpp }}" build {{ preset }} -- --target telar-runtime telar telar-gateway

# Build the GUI in the tree of PRESET.
gui-build preset="dev": (configure preset)
    "{{ cpp }}" build {{ preset }} -- --target telar-gui telar-gui-command

# Build the gateway in the tree of PRESET.
gateway-build preset="dev": (configure preset)
    "{{ cpp }}" build {{ preset }} -- --target telar-gateway

# Build the diagram renderer that the macOS bundle ships beside the runtime. It needs Cargo.
renderer:
    cargo build --release --locked --manifest-path "{{ renderer_dir }}/Cargo.toml" --target-dir "{{ renderer_dir }}/target"

# Build everything, start an isolated development runtime and open the GUI on it.
app: dev-bin gui-build (dev-app gui dev_dir)

# Run optimized GUI/runtime builds with development config and their own socket/history.
app-release: (dev-bin "release" release_dev_dir) (gui-build "release") (dev-app (build_dir / "release/src/gui/telar-gui") release_dev_dir)

# Build and run the runtime on the development socket. Extra arguments are passed to it.
run *args: runtime-build
    mkdir -p -m 700 "{{ dev_dir }}"
    TELAR_DEVELOPMENT_CONFIG="{{ justfile_directory() }}/dev/config.lua" TELAR_SOCKET="{{ dev_dir }}/runtime.sock" TELAR_HISTORY="{{ dev_dir }}/history.db" "{{ runtime }}" {{ args }}

# Stop only the Debug development runtime.
stop:
    TELAR_SOCKET="{{ dev_dir }}/runtime.sock" "{{ cli }}" server stop

# Stop only the Release development runtime, including its panes.
stop-release:
    TELAR_SOCKET="{{ release_dev_dir }}/runtime.sock" "{{ build_dir }}/release/src/runtime/telar" server stop

# Build everything and run every test. Extra arguments are passed to CTest.
test *args: dev-bin
    "{{ cpp }}" build dev
    "{{ cpp }}" test dev -- {{ args }}

# Build and run the runtime and CLI tests. Extra arguments are passed to CTest.
runtime-test *args: (configure "dev")
    "{{ cpp }}" build dev -- --target src/runtime/all src/cli/all
    "{{ cpp }}" test dev -- -L '^(runtime|cli)\.' {{ args }}

# Build and run the GUI tests, the integration ones against the runtime. Extra arguments are passed to CTest.
gui-test *args: dev-bin
    "{{ cpp }}" build dev -- --target src/gui/all
    "{{ cpp }}" test dev -- -L '^gui\.' {{ args }}

# Build and run the tests of one domain or library by its label, `just domain-test runtime.terminal`, without the other tests or the CLI the GUI's integration cases need.
domain-test label *args: (configure "dev")
    "{{ cpp }}" build dev -- --target {{ replace(replace_regex(label, '^lib\.', 'telar.'), ".", "-") }}-tests
    "{{ cpp }}" test dev -- -L '^{{ replace(label, ".", "\\.") }}$' {{ args }}

# Run cases of the window test alone, each in a couple of seconds: `just gui-case tabsCloseInOrder`.
# Without a case it runs them all; `just gui-case -functions` lists them.
gui-case *args: dev-bin
    "{{ cpp }}" build dev -- --target gui-quick-test
    cd "{{ build_dir }}/dev/src/gui" && TELAR_GUI_TEST_RUNTIME="{{ dev_telar }}" PATH="{{ build_dir }}/dev/src/runtime:$PATH" QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen ./gui-quick-test {{ args }}

# Compare the editor pane's surfaces with their reference pictures, with both presets:
# `just gui-references`. `just gui-references update` takes the pictures again, to review
# in the diff. They are pictures of this platform's fonts.
gui-references mode="compare": dev-bin
    "{{ cpp }}" build dev -- --target gui-quick-test
    cd "{{ build_dir }}/dev/src/gui" && for preset in zenburn vesper; do rm -rf /tmp/telar-picker; {{ if mode == "update" { "TELAR_EDITOR_REFERENCES_UPDATE=1" } else { "" } }} TELAR_EDITOR_REFERENCES="{{ justfile_directory() }}/src/gui/tests/references/editor" TELAR_EDITOR_PRESET=$preset TELAR_GUI_TEST_RUNTIME="{{ dev_telar }}" PATH="{{ build_dir }}/dev/src/runtime:$PATH" QT_QUICK_BACKEND=software QT_QPA_PLATFORM=offscreen ./gui-quick-test editorPaneDrawsNeovim || exit 1; done

# Refresh the compilation database and generated headers that clangd reads in out/dev.
editor: (configure "dev")
    "{{ cpp }}" build dev -- --target cell-layout gui-editor --parallel 2

# Check the C++ sources of the dev tree with clang-tidy, without its static analyzer or applying fixes.
lint: lint-scope (configure "dev")
    "{{ cpp }}" exec -- cmake -DCHECK=lint "-DBUILD_DIRECTORY={{ build_dir }}/dev" -P cmake/scripts/check.cmake

# Run clang-tidy's static analyzer over the sources lint checks, in its shallow mode; `just analyze deep` runs the whole analysis, five times as long.
analyze depth="shallow": lint-scope (configure "dev")
    "{{ cpp }}" exec -- cmake -DCHECK=analyze "-DDEEP={{ if depth == "deep" { "ON" } else { "OFF" } }}" "-DBUILD_DIRECTORY={{ build_dir }}/dev" -P cmake/scripts/check.cmake

# Build the clang-tidy plugin that keeps lint and analyze from walking what each unit imports.
lint-scope: tbc-configure
    "{{ cpp }}" build tbc -B lib/tbc/out/release -- --target tbc-tidy-scope

# Build the optimized lifetime checker that the repository's .tbc.json names.
lifetime-checker: tbc-configure
    "{{ cpp }}" build tbc -B lib/tbc/out/release -- --target tbc-lint

# Check the lifetimes of the C++ sources of the dev tree.
lifetime: lifetime-checker (configure "dev")
    "{{ cpp }}" exec -- cmake -DCHECK=lifetime "-DBUILD_DIRECTORY={{ build_dir }}/dev" -P cmake/scripts/check.cmake

# Run tbc-lint's four checks over the dev tree in one pass, which parses each source once.
checks: lifetime-checker (configure "dev")
    "{{ cpp }}" exec -- cmake -DCHECK=lifetime+interface_bodies+blank_lines+standard_containers "-DBUILD_DIRECTORY={{ build_dir }}/dev" -P cmake/scripts/check.cmake

# Check that the module interfaces keep no function body outside the allowlist.
interface-bodies: lifetime-checker (configure "dev")
    "{{ cpp }}" exec -- cmake -DCHECK=interface_bodies "-DBUILD_DIRECTORY={{ build_dir }}/dev" -P cmake/scripts/check.cmake

# Check that telar code uses telar::ds rather than the standard containers it replaces, outside the allowlist.
standard-containers: lifetime-checker (configure "dev")
    "{{ cpp }}" exec -- cmake -DCHECK=standard_containers "-DBUILD_DIRECTORY={{ build_dir }}/dev" -P cmake/scripts/check.cmake

# Check the blank lines of docs/code-style.md; FIX=ON inserts them.
blank-lines fix="OFF": lifetime-checker (configure "dev")
    "{{ cpp }}" exec -- cmake -DCHECK=blank_lines "-DBUILD_DIRECTORY={{ build_dir }}/dev" "-DFIX={{ fix }}" -P cmake/scripts/check.cmake

# Check the layers of src/gui/ui at a revision: no cycle, and no folder using one the UI rules forbid.
ui-rules rev="HEAD":
    python3 tools/ui-graph.py "{{ rev }}" --rules

# Format every C++, Objective-C++ and module file in the repository with the root .clang-format.
format:
    "{{ cpp }}" exec -- cmake -P cmake/scripts/format.cmake

# Check the formatting of every C++, Objective-C++ and module file without changing it.
format-check:
    "{{ cpp }}" exec -- cmake -DMODE=format-check -P cmake/scripts/format.cmake

# Package the Release Telar.app, install it under APPS and link its `telar` into BIN.
[macos]
install-gui apps=(home_directory() / "Applications") bin=(home_directory() / ".local/bin"): renderer (configure "dist") (configure "release")
    #!/usr/bin/env bash
    set -euo pipefail
    stage="{{ dev_dir }}/stage"
    app="Telar.app"
    rm -rf "$stage"
    "{{ cpp }}" build dist
    "{{ cpp }}" exec -- cmake --install "{{ build_dir }}/dist" --prefix "$stage"
    install -m 755 "{{ renderer }}" "$stage/bin/telar-diagram-renderer"
    "{{ cpp }}" build release -- --target telar-gui telar-gui-command
    python3 "{{ justfile_directory() }}/src/gui/tools/package_macos.py" --release --build "{{ build_dir }}/release" --runtime-prefix "$stage" --output "$stage/$app"
    mkdir -p "{{ apps }}" "{{ bin }}"
    rm -rf "{{ apps }}/$app"
    cp -R "$stage/$app" "{{ apps }}/$app"
    ln -sf "{{ apps }}/$app/Contents/Resources/bin/telar" "{{ bin }}/telar"

# Build EBNF and run its GoogleTest suite with color in the ci tree. Extra arguments are forwarded to CTest.
[positional-arguments]
ebnf-test *args:
    "{{ cpp }}" configure ci
    "{{ cpp }}" build ci -- --target ebnf ebnf_tests
    GTEST_COLOR=yes "{{ cpp }}" test ci -- -L lib.ebnf -V "$@"

# Configure the tree of PRESET; a tree with tests runs the GUI's integration tests against the development CLI.
configure preset="dev":
    "{{ cpp }}" configure {{ preset }} -- {{ if preset == "release" { "" } else if preset == "dist" { "" } else { test_options } }}

playground:
  cmake --build out/dev --target gui-playground
  out/dev/src/gui/gui-playground src/gui/playground/play.qml

[private]
tbc-configure:
    "{{ cpp }}" configure tbc -B lib/tbc/out/release --config Release -- -DBUILD_TESTING=OFF

[private]
dev-bin preset="dev" state_dir=dev_dir: (runtime-build preset)
    mkdir -p -m 700 "{{ state_dir }}" "{{ state_dir }}/bin"
    ln -sf "{{ build_dir }}/{{ preset }}/src/runtime/telar" "{{ state_dir }}/bin/telar"

[private]
dev-app binary state_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="{{ state_dir }}/bin:$PATH" TELAR_SOCKET="{{ state_dir }}/runtime.sock" TELAR_HISTORY="{{ state_dir }}/history.db"
    export TELAR_BIN_PATH="{{ state_dir }}/bin/telar" TELAR_SOCKET_PATH="$TELAR_SOCKET"
    export TELAR_DEVELOPMENT_CONFIG="{{ justfile_directory() }}/dev/config.lua"
    "{{ state_dir }}/bin/telar" server endpoint > /dev/null
    exec "{{ binary }}"

alias b := build
alias r := run
