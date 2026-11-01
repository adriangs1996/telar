# tbc

C++23 lifetime annotations and a Clang AST linter. This is an initial, limited
implementation, not a Rust borrow checker. Run project commands from `dlls/tbc`.

[Rust borrow checker rules](docs/rust-borrow-checker.md) catalogs the source rules,
exceptions, and analysis boundaries, with official references and checked examples.

## Requirements

- CMake 3.25+, Ninja, and a C++23 compiler.
- LLVM/Clang 18+ development libraries for `tbc-lint`, including `clang-cpp`.
- `clangd`, `clang-format`, and `clang-tidy`, preferably from that LLVM installation.
- Python 3 for CLI contract tests.
- Network access on the first test configure to fetch the pinned GoogleTest archive.

On macOS:

```sh
brew install cmake ninja llvm
export PATH="$(brew --prefix llvm)/bin:$PATH"
export CMAKE_PREFIX_PATH="$(brew --prefix llvm)${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export CC=clang CXX=clang++
```

On Ubuntu 24.04:

```sh
sudo apt-get install cmake ninja-build clang-18 llvm-18-dev libclang-18-dev libclang-cpp18-dev clang-tools-18 clang-format-18 clang-tidy-18 python3
export PATH="/usr/lib/llvm-18/bin:$PATH"
export CMAKE_PREFIX_PATH="/usr/lib/llvm-18${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export CC=clang CXX=clang++
```

Other installations can pass `-DLLVM_DIR=/prefix/lib/cmake/llvm` and
`-DClang_DIR=/prefix/lib/cmake/clang`. Keep the Clang libraries and resource headers
from the same installation. The linter uses their configured resource directory;
reconfigure and rebuild it after replacing that LLVM installation.

## Build and test

```sh
cmake --preset debug -DTBC_WARNINGS_AS_ERRORS=ON
cmake --build --preset debug
ctest --preset debug
./out/debug/tbc-example
```

Presets limit build and test concurrency to two jobs. Debug, Release, and sanitizer
builds use separate directories. Sanitizers enable ASan and UBSan for project
executables, not prebuilt LLVM libraries.

```sh
cmake --preset sanitize
cmake --build --preset sanitize
ctest --preset sanitize
```

Tests use the same pinned GoogleTest commit and SHA-256 as `dlls/ebnf`. For an
offline checkout, pass `-DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/path/to/googletest`.
New `tests/**/*_test.cpp` files and GoogleTest cases are discovered automatically.
Intentional diagnostic fixtures are not compiled as unit tests or included in
normal clang-tidy analysis.

## Library

`tbc::tbc` is header-only. Consumers only need a C++23 compiler, not LLVM, Python,
or GoogleTest. To configure and install without those dependencies:

```sh
cmake --preset library
cmake --build --preset library
cmake --install out/library --prefix /your/install/prefix
```

Consumers can use `add_subdirectory` or the installed package:

```cmake
find_package(tbc 0.1 CONFIG REQUIRED)
target_link_libraries(your_target PRIVATE tbc::tbc)
```

Project warning and sanitizer flags do not propagate through `tbc::tbc`.

```cpp
#include <tbc/view.hpp>
#include <string_view>

using text_a = tbc::view<std::string_view, tbc::lt::a>;

text_a longerText(text_a first, text_a second) {
  return first.size() > second.size() ? first : second;
}
```

[`docs/contracts.md`](docs/contracts.md) describes the signature design. Repeated
`lt::a` denotes a common region, not one particular argument or allocation.
The linter instantiates region variables per call. `lt::b`, `lt::c`, and
`lt::d` describe independent variables. Visible helpers need no annotation:

```cpp
std::string_view prefix(std::string_view input) {
  return input.substr(0, 3);
}
```

`tbc::view<T>` also requests inference/elision without an explicit label.

`view<T, region>` is an alias for `T`: ordinary calls, native methods, layout,
and ABI remain unchanged. No macros, external traits, or parameter-name strings
are required. Clang retains the spelled aliases for the linter. C++ itself does
not prevent assignment between regions. The checker follows inferred dependencies
and checks explicit return regions. General effect analysis remains incomplete.

`<tbc/lifetime.hpp>` also provides descriptive `lifetime<tag>` labels and the
older pointer-backed `borrow<T, scope>` utility. The signature examples use
`view`, not that wrapper. `<tbc/contracts.hpp>` is an umbrella include, not a
separate contract language.

## Lifetime linter

```sh
./out/debug/tbc-lint -p out/debug main.cpp
./out/debug/tbc-lint --warnings-as-errors -p out/debug main.cpp
cmake --build --preset debug --target lifetime-check
```

The compilation database supplies C++23 flags, includes, definitions, and the
macOS SDK. For an isolated source file, arguments after `--` replace the database:

```sh
./out/debug/tbc-lint tests/fixtures/dangling.cpp -- -std=c++23 -Iinclude
```

Native borrowed returns are checked without annotation:

```cpp
const int &invalid() {
  const int local = 7;
  return local; // tbc-dangling-borrow
}
```

The checker builds CFGs and infers function summaries for visible project bodies,
including instantiated templates and included headers. It follows aliases,
borrowed aggregate fields, copies/moves, direct constructor initializers, reachable
branches, recursive call chains, and modeled invalidations. It distinguishes a
copied descriptor's contents from a reference to the descriptor object itself.

Explicit `view<T, region>` contracts remain binding. They can be written once on
a declaration while its definition uses native types. The checker reads spelled
alias information before canonicalization and matches parameter positions, not
names. Missing or unsupported borrowed-result dependencies produce
`tbc-missing-contract` rather than an assumed static lifetime.

Exit codes are 0 for success, including nonfatal warnings; 1 for analysis or
compilation failure; and 2 for invalid CLI arguments. `--warnings-as-errors`
promotes the checker's diagnostics to errors. Diagnostics use Clang's
`file:line:column: severity: message [tbc-dangling-borrow]` format and include a
note at the referent's declaration. An invalidated borrow also has a note at its
first later use.

The linter detects invalid memory uses in the project's code. Code the project
does not control is used to infer what the project borrows, never reported: a
call into a compiled third-party function, or an expression spelled inside a
system-header macro such as GoogleTest's assertion machinery, does not produce
`tbc-missing-contract`. A project expression passed as a macro argument is still
checked. Annotations are only requested for project code that cannot be inferred.

### Limits

- Borrows record how deep they reach inside a variable and the fields on the way:
  the object, its element slots, and each level owned below them. Mutating a
  nested node, an object owned through a pointer, or one field leaves the other
  places valid, and assigning or clearing one field replaces only what it held.
  Paths keep a bounded number of fields, union members share one place, and the
  elements of one container are still merged, so erasing at a position is not
  modeled. Moving a smart pointer or an allocator-aware container hands its
  object to the destination; `unique_ptr::release` and swaps through opaque
  project functions are not followed.
- Emplacement forwards its arguments to an element constructor; only standard
  elements are assumed to keep them, so `map.emplace(key, std::string)` into a
  view element is not tracked. Constructors and functions defined in another
  translation unit, virtual dispatch, and allocators remain contract boundaries.
- Deferred captures, allocator/destructor dependencies, foreign invalidation,
  exception unwinding, mutable globals, and indirect dispatch remain incomplete.
- Bounds, nullability, initialization, concurrency, and explicit outlives bounds
  remain separate implementation targets. Rust's exclusive aliasing rules are not
  a target: overlapping mutable references are legal C++.

A clean run is not proof of arbitrary C++ memory safety. See
[`docs/contracts.md`](docs/contracts.md) for supported inference, boundary rules,
and limitations. The paired inference corpus checks both acceptance and exact
rejection diagnostics; it never executes the negative examples.

## Neovim

Configure Debug before editing. `.clangd` selects `out/debug/compile_commands.json`
without symlinks. Your existing clangd and Conform setup already recognizes the
project root, C++ flags, formatting rules, navigation, and compiler diagnostics.
No change to global clangd or formatting configuration is required.

`editor/neovim.lua` is a Lazy.nvim plugin spec for `nvim-lint`. Install it into a
LazyVim configuration with:

```sh
ln -s "$PWD/editor/neovim.lua" "${XDG_CONFIG_HOME:-$HOME/.config}/nvim/lua/plugins/tbc.lua"
```

Restart Neovim after installation. `:TbcLint` checks the saved C++ buffer; saving a
C++ source or header also runs it asynchronously. It does not run on keystrokes
or leaving insert mode. Only projects containing `.tbc.json` opt in; other C++
projects' linters remain unchanged. Build the checker and configure the consumer's
compilation database first. Diagnostics use `vim.diagnostic` with source
`tbc-lint`.

`.tbc.json` specifies a project-relative `linter`, `build_directory`, and
`header_translation_unit`. Header checks use that translation unit so templates
are instantiated. Absolute paths are supported; `TBC_LINTER` overrides the command.
`dlls/ebnf/.tbc.json` points at the sibling checker and at `main.cpp`, which
explicitly instantiates the parser without test code.

## Project-derived implementation specifications

[`tests/spec/README.md`](tests/spec/README.md) describes a compile-only corpus
based on `runtime-cpp`, `gui-cpp`, and `dlls/ebnf`. Each case names its source,
contract, scenario, exact expected diagnostics, and implementation status.
Accepted and rejected examples are grouped together. Borrowed types use public
`view` aliases with region labels or elision directly in signatures and fields.
There are no external traits or parameter-name selectors. Resource invalidation,
callback retention, and other operation effects remain explicit acceptance
requirements in each case's comments; they are not yet encoded by a new effect API.

```sh
ctest --preset debug -L spec
cmake --build --preset debug --target spec-check
```

The first command validates fixture syntax/metadata, the runner, and implemented
regressions. `spec-check` deliberately fails on unmet pending specifications.
The corpus has 216 cases: 170 implemented regressions and 46 explicitly pending
requirements. Fixtures are never linked or executed. Provenance validation requires the surrounding Telar checkout.

## Format and static analysis

```sh
cmake --build --preset debug --target format
cmake --build --preset debug --target format-check
cmake --build --preset debug --target lint
```

Formatting and generic clang-tidy tooling follow `dlls/ebnf`: LLVM style, two
spaces, braces, unbounded signature lines, separate definitions, and no forced
trailing return types. `.editorconfig` defines UTF-8, LF, and final newlines.
`lint` is clang-tidy; `lifetime-check` is the annotation-aware linter. Both fail on
selected diagnostics. Builds, generated sources, and dependencies are excluded.
C++ types, aliases, concepts, and type template parameters use `snake_case`, as
in `view`, `lifetime`, and `lifetime_type`. Functions and methods use
`camelCase`, as in `isView`. Macros use `UPPER_SNAKE_CASE`. The type and function
naming rules are enforced by `readability-identifier-naming` in `.clang-tidy`.

Local build overrides belong in ignored `CMakeUserPresets.json`; build output and
editor caches are also ignored. `.github/workflows/tbc.yml` validates the project
on Linux and macOS without running Telar's unrelated suites.
