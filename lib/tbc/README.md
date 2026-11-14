# tbc

C++23 lifetime annotations and a Clang AST linter that applies Rust's borrow
checking rules to C++: each function is checked on its own, and calls are known
by their declarations. It is a limited implementation, not a proof of memory
safety. Run project commands from `lib/tbc`.

[Rust borrow checker rules](docs/rust-borrow-checker.md) catalogs the source rules,
exceptions, and analysis boundaries, with official references and checked examples.

## Requirements

Use the [shared pinned toolchain](../../docs/build/cpp-modules.md). From the
repository root, run `tools/cpp bootstrap`, then add `.toolchain/bin` to `PATH`.
This provides LLVM/clangd 23.1.5, CMake 4.4.5, Ninja 1.13.2 and Just 1.59.0.
The presets select `.toolchain/toolchain.cmake`; do not mix compiler installations
inside an existing build directory. Python 3.9+ and the native development SDK
are prerequisites. The first test configure fetches verified GoogleTest sources.

The TBC annotations remain textual because their macros and source locations are
consumed by Clang AST analysis. The pinned LLVM distribution also supplies the
linter development headers, libraries and resource directory. No separate
Homebrew or distro LLVM SDK is needed.

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

Tests use the same pinned GoogleTest commit and SHA-256 as `lib/ebnf`. For an
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

A telar module unit imports the same declarations as `telar.tbc` instead of
including `<tbc/view.hpp>`, and includes `<tbc/annotations.hpp>`, which includes
nothing, when it needs `TBC_SHARED`, `TBC_CONSTRUCTS` or `TBC_RAW`.

[`docs/contracts.md`](docs/contracts.md) describes the signature design. Repeated
`lt::a` denotes a common region, not one particular argument or allocation.
The linter instantiates region variables per call. `lt::b`, `lt::c`, and
`lt::d` describe independent variables. Helpers that Rust's lifetime elision
describes need no annotation:

```cpp
std::string_view prefix(std::string_view input) {
  return input.substr(0, 3);
}
```

`tbc::view<T>` also requests elision without an explicit label.

`view<T, region>` is an alias for `T`: ordinary calls, native methods, layout,
and ABI remain unchanged. No macros, external traits, or parameter-name strings
are required. Clang retains the spelled aliases for the linter. C++ itself does
not prevent assignment between regions. The checker checks every definition
against its declaration and every call against the callee's declaration.

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

Several sources are checked in parallel, one per physical core unless `-j N`
says otherwise; each source's diagnostics are printed together. Consumer projects
name the optimized checker in their `.tbc.json`, which `just lifetime-checker`
builds at `out/release/tbc-lint`. `just runtime-lifetime` checks the runtime, the
CLI and the telar libraries, `just gui-lifetime` the GUI, and the `lifetime-check`
target each standalone library and the auth daemon.

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

The checker builds a CFG for each project function, including instantiated
templates and included headers, and follows aliases, borrowed aggregate fields,
copies/moves, constructor initializers, reachable branches and loops, and the
standard library's modeled effects within it. A call is known by its declaration:
its result follows elision or labels, it keeps only what its labels let it keep,
and it uses everything it receives. What it can invalidate is the one effect
summarized across calls, an input at a time, never field by field, as Rust's
`&mut` lends a whole object. When several sources are checked, a first pass
summarizes that effect for the functions each one defines, so a call into
another unit invalidates what its body does rather than every input it can
mutate; see [`docs/contracts.md`](docs/contracts.md#functions-another-unit-defines). A closure is checked with its enclosing function.
An object never borrows itself, and a call's mutable argument never overlaps
another argument.

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
checked. Annotations are only requested where Rust would need an explicit lifetime.

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
- Reads and writes through an input follow what it designates, and past it each
  reference field, at most three times. What a pointer held in a field
  designates stays merged with the object that holds the pointer. Distinct
  inputs, and the objects reached through different dereferences of one input,
  are assumed not to alias, which each call's overlap check and the ban on
  self-borrowing objects uphold.
- Emplacement forwards its arguments to an element constructor; only standard
  elements and pointers are assumed to keep them, so
  `map.emplace(key, std::string)` into a view element is not tracked.
  A declaration's contract, elided or labeled, is checked against its
  definition in the translation unit that defines it. A type marked
  `TBC_SHARED`, such as an allocator, is trusted to keep the borrows it hands out
  valid. One label names one region, so `&'s Stream<'b>` cannot yet be stated.
- Deferred captures, allocator/destructor dependencies, foreign invalidation,
  exception unwinding, mutable globals, and indirect dispatch remain incomplete.
- Bounds, nullability, initialization, concurrency, and explicit outlives bounds
  remain separate implementation targets. Exclusive aliasing is checked per call
  and per object; two objects that each keep the same mutable reference are not
  reported.

A clean run is not proof of arbitrary C++ memory safety. See
[`docs/contracts.md`](docs/contracts.md) for supported inference, boundary rules,
and limitations, and [`docs/open-problems.md`](docs/open-problems.md) for what
real code still shows. The paired inference corpus checks both acceptance and exact
rejection diagnostics; it never executes the negative examples.

## Blank lines

`--checks=blank-lines` checks the blank lines that the repository's
[code style](../../docs/code-style.md#logical-blocks) asks for between the
statements of a block, on the AST instead of on text:

- `tbc-blank-line-after-block`: a statement that ends on its own closing brace
  (a loop, an `if`, a `switch`, a multi-line lambda or braced list) is followed
  by a blank line. `else`, `catch` and the `while` of a `do` belong to the same
  statement, and the closing brace of the block or a `case` label needs none.
- `tbc-blank-line-after-declarations`: a run of declarations is followed by a
  blank line before the first statement that is not one. An `if` whose
  condition uses a variable the declaration right above it introduces stays
  attached to it.

A statement macro reads as a statement where it is used, even when it expands
to a declaration, so a trace such as `TELAR_TRACE("name");` at the top of a
function needs no blank line after it.

```sh
./out/debug/tbc-lint --checks=blank-lines -p out/debug main.cpp
./out/debug/tbc-lint --checks=blank-lines --fix --header-filter='/src/.*\.hpp$' -p out/debug main.cpp
```

`--fix` inserts each missing blank line right below the statement that asks for
it, above any comment that describes the next block, and never removes one: a
blank line that is already there may separate two blocks by what they do, which
is the part of the rule that cannot be automated. Main files are checked;
headers only when their path matches `--header-filter`, and a header that
several units include is reported and fixed once. Checks combine, as in
`--checks=lifetime,blank-lines`; without `--checks` only lifetimes are checked.

## Interface bodies

`--checks=interface-bodies` reports `tbc-interface-body` on each function body
that a module interface unit (`export module X;` or `export module X:part;`)
keeps in its purview. An interface carries declarations; a body belongs to an
implementation unit, so that changing it recompiles that unit and not every
importer. Templates are reported too: their bodies move to an implementation
unit that instantiates them explicitly, behind `extern template` in the
interface.

These bodies stay:

- `constexpr` and `consteval` functions, whose bodies importers evaluate, and a
  lambda that a `constexpr` variable holds when it can be evaluated too.
- Hot paths marked `TBC_HOT_PATH`, from `<tbc/hot_path.hpp>`, so that importers
  can inline them. A marked function that is not a template must also be
  `inline`: the body of a non-inline function never reaches an importer, and a
  member defined in its class is not implicitly inline in a module. On a class,
  the mark covers the bodies of all its members, as for a small template that
  stays one; on a variable, the lambdas that initialize it.

```cpp
export TBC_HOT_PATH inline std::size_t next(std::size_t index) {
  return index + 1;
}

export template <typename type>
class TBC_HOT_PATH Vector {
  // ...
};
```

What the global module fragment includes and what follows `module :private;`
are no part of the interface, and implementation units are not checked. A body
that a function holds, such as a local class or a lambda, belongs to it.

```sh
./out/debug/tbc-lint --checks=interface-bodies --interface-allowlist=allowlist.txt -p out/debug interface.cppm
```

`--interface-allowlist` names the modules that may still keep bodies, one per
line, where blank lines and lines starting with `#` are ignored. A partition
counts as its module. The allowlist also reports an allowed module whose checked
interfaces keep no body, so that its entry is removed once its bodies move.

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
`lib/ebnf/.tbc.json` points at the sibling checker and at `main.cpp`, which
explicitly instantiates the parser without test code.

## Project-derived implementation specifications

[`tests/spec/README.md`](tests/spec/README.md) describes a compile-only corpus
based on `runtime-cpp`, `gui-cpp`, and `lib/ebnf`. Each case names its source,
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
The corpus has 360 cases: 309 implemented regressions and 51 explicitly pending
requirements. Fixtures are never linked or executed. Provenance validation requires the surrounding Telar checkout.

## Format and static analysis

```sh
cmake --build --preset debug --target format
cmake --build --preset debug --target format-check
cmake --build --preset debug --target lint
cmake --build --preset debug --target blank-lines
```

`format` uses the repository root's `.clang-format`, and `blank-lines` checks the
blank lines of `docs/code-style.md` with the `tbc-lint` this project builds. Generic
clang-tidy tooling follows `lib/ebnf` and forces no trailing return types. `.editorconfig` defines UTF-8, LF, and final newlines.
`lint` is clang-tidy; `lifetime-check` is the annotation-aware linter. Both fail on
selected diagnostics. Builds, generated sources, and dependencies are excluded.
C++ types, aliases, concepts, and type template parameters use `snake_case`, as
in `view`, `lifetime`, and `lifetime_type`. Functions and methods use
`camelCase`, as in `isView`. Macros use `UPPER_SNAKE_CASE`. The type and function
naming rules are enforced by `readability-identifier-naming` in `.clang-tidy`.

Local build overrides belong in ignored `CMakeUserPresets.json`; build output and
editor caches are also ignored. `.github/workflows/tbc.yml` validates the project
on Linux and macOS without running Telar's unrelated suites.
