# ebnf

Standalone C++23 project. Run these commands from `lib/ebnf`.

## Requirements

Use the [shared pinned toolchain](../../docs/build/cpp-modules.md). From the
repository root, run `tools/cpp bootstrap`, then add `.toolchain/bin` to `PATH`.
This provides LLVM/clangd 23.1.5, CMake 4.4.5, Ninja 1.13.2 and Just 1.59.0.
The presets select `.toolchain/toolchain.cmake`; do not mix compiler installations
inside an existing build directory. Python 3.9+ and the native development SDK
are prerequisites. The first test configure fetches verified GoogleTest sources.

The lexer, parser and matcher are real module interfaces; link `ebnf::ebnf` and
import `telar.ebnf.lexer`, `telar.ebnf.parser` or `telar.ebnf.matcher`. TBC
annotation headers remain textual.

## Build and test

With Just installed, configure, build, and run tests with GoogleTest colors in one
command. Run from the repository root or `lib/ebnf`. Extra arguments go to CTest:

```sh
just ebnf-test
just ebnf-test -R '^Lexer\.'
just ebnf-test -R '^Grammar\.' --stop-on-failure
```

The recipe uses the Debug preset and verbose test output so successful tests also
show their GoogleTest output. Without Just, run the steps directly:

```sh
cmake --preset debug
cmake --build --preset debug
ctest --preset debug
./out/debug/ebnf
```

The executable currently only returns success. `ebnf-smoke` checks that it starts
and exits successfully. `ToolchainTest.Cpp23IsEnabled` is the initial GoogleTest
check; it verifies the language mode, not parser behavior.

GoogleTest v1.18.0 is fetched into each build directory with a pinned commit and
SHA-256 checksum. It is only needed when `BUILD_TESTING=ON`. To build without tests
or downloading GoogleTest:

```sh
cmake --preset release -DBUILD_TESTING=OFF
cmake --build --preset release
```

For an existing offline checkout, pass
`-DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/path/to/googletest` when configuring.

CMake discovers `.cpp`, `.cc`, and `.cxx` files under `tests/`, including
subdirectories. Adding or removing a source file is detected on the next build;
no CMake edits are needed. CTest discovers individual `TEST` and `TEST_F` cases
automatically. To run one suite:

```sh
ctest --preset debug -R '^ToolchainTest\.'
```

## Lexer and parser boundary

`lexer.cppm` groups ASCII identifiers, numbers, quoted literals and `@name`
dynamic terminals into tokens. Whitespace and ISO 14977 comments `(* ... *)`,
which nest and may hold any byte, are discarded outside literals; whitespace is
preserved inside them. Both quote styles are supported; a `String` token contains
the literal text without quotes. Literals are nonempty and accept printable ASCII
plus the whitespace characters; control characters and non-ASCII bytes are
rejected. The lexer validates `\n`, `\t`, `\r`, `\f`, `\b`, `\\`, `\'`, and `\"`
inside either quote style. Escaped quotes do not close a literal. Unknown or
incomplete escapes throw `std::invalid_argument`. Token and AST text preserve the
original escape spelling without decoding or allocating new text.

`Lexer::tokenizeSourceIntoBuffer` returns the number of tokens written, including
one final `End`. The capacity argument includes that terminator. Invalid input
throws `std::invalid_argument`; insufficient capacity throws `std::length_error`
rather than silently truncating the input. Token text borrows the source storage.

`parser.cppm` consumes complete tokens. `parseIdentifier()` and `parseString()`
return source-backed views; character recognition and whitespace handling belong
to the lexer. Tokenizer implementations must return `std::size_t` and include
`End` in their reported count. `parse()` resets the token cursor before reading.

Run the lexer and parser-boundary tests with:

```sh
ctest --preset debug -R '^(Lexer\.|Grammar\.)'
```

## Syntax tree

`parser.cppm` is a recursive-descent parser that builds a flat tree: each node has
a kind, a source-backed `text`, a first child and a next sibling.

| Source | Node |
| --- | --- |
| `name = body ;` (or `.`) | `Rule` with the name in `text` and one body child |
| `a , b` | `Concatenation` with one child per factor |
| `a \| b` | `Alternative`; every branch is a `Concatenation`, even of one factor |
| `( a )` | the inner node; there is no group node |
| `[ a ]`, `a ?` | `Optional` with one child |
| `{ a }`, `a *` | `ZeroOrMore` with one child |
| `a +` | `OneOrMore` with one child |
| `a - b` | `Exception` with the children `a` and `b` |
| `"text"`, `'text'` | `Literal`; `text` excludes the quotes |
| `name` | `Reference`; resolved later, so forward references are allowed |
| `@name` | `Dynamic`; `text` is the provider name without `@` |
| `terminal : "text"` | a `Description` child under that `Literal` or `Dynamic` |
| `"prefix" ~ value` | `Glue` with the children prefix and value |

Concatenation needs explicit commas. Every syntax error throws
`std::invalid_argument`. Brackets nest at most `max_nesting_depth` (64) levels, so
recursion stays bounded for untrusted specs. The caller must keep the source text
alive while the tree's text views use it.

```sh
ctest --preset debug -R '^(AST|Alternation|Concatenation|Factor|Term|Rule|Comment|Dynamic|Description|Glue|SyntaxError|Literal)\.'
```

## Command specs

A command spec is an EBNF grammar over the words of one command line.
`telar.ebnf.matcher` compiles it and answers completion and validation queries
with an Earley recognizer whose terminals match whole words. Specs ship in
`specs/` for `git`, `cd`, `ssh`, `make` and `kill`; their flags were checked
against `--help` and the man pages of the tools they describe.

```ebnf
(* The first rule is the start symbol. It matches the words after the command name. *)
git = { global } , [ command ] ;
global = "-C" : "Run as if started in this path" , @directory | "--no-pager" ;
command = "switch" : "Switch branches" , { switch_option | @branch } ;
switch_option =
    "-c" : "Create and switch to a new branch" , @any
  | "--color=" : "When to color" ~ ( "always" | "never" | "auto" )
  | "-q" | "--quiet" ;
```

The extensions to ISO 14977:

- `@name` is a dynamic terminal: one word whose values a provider named `name`
  supplies, such as `@branch`, `@file`, `@directory`, `@command` or `@ssh_host`.
  The caller resolves providers; the matcher only reports where they are
  expected. A dynamic terminal matches any word that does not look like an
  option (a word longer than `-` that starts with `-`), so unknown flags stay
  invalid. Two names have built-in meaning: `@any` matches every word, including
  option-like ones, and `@number` matches decimal digits.
- `terminal : "text"` attaches a description to a literal or dynamic terminal.
  To describe an alternative, describe its first literal.
- `"prefix" ~ value` matches one word that starts with the prefix and ends with
  the value, as in `--color=auto` or `-U5`. The value is a literal, a dynamic
  terminal, or an alternation of them, possibly through a rule reference. Inside
  a glued word a dynamic value matches any nonempty rest.
- Options in any order use the plain EBNF idiom `{ option | operand }`: one
  repetition of an alternation, compiled to a left-recursive rule whose Earley
  sets stay small however many options the line has.
- `--` and positional structure are ordinary grammar, as in
  `{ option | @file } , [ "--" , { @file } ]`.

A word that no terminal matches whole and that looks like a short-option cluster
(`-abc`) is read as getopt reads it: the flags `-a -b -c`, where any of them may
take the rest of the word as its value (`-mmessage`, `-p2222`). Every reading is
kept, so a few clusters getopt would reject are accepted. Unique-prefix
abbreviations of long options are not modelled. The exception operator `-` parses
but is rejected when a spec is compiled.

```cpp
import telar.ebnf.matcher;

const auto git = ebnf::command_spec::compile(source); // throws on any error
auto scratch = std::make_unique<ebnf::match_scratch>(); // one per thread
std::array<ebnf::candidate, 64> out{};
const std::array<std::string_view, 2> words{"switch", "--quiet"}; // after "git", unquoted

const auto result = git.complete(words, "ma", *scratch, out);
for (const auto &candidate : std::span{out}.first(result.count)) {
  // literal: insert prefix + text; provider: resolve text, insert prefix + value.
}

if (const auto checked = git.check(words, *scratch); checked.status == ebnf::match_status::invalid) {
  // words[checked.word] is the first word no derivation accepts.
}
```

`compile()` throws `std::invalid_argument` for syntax or semantic errors
(undefined or duplicate rules, `-`, a bad glued value) and `std::length_error`
past a compile limit. The compiled `command_spec` owns its decoded text, so the
source can be released; it is immutable and can be shared across threads.

`complete()` returns the candidates valid for the next word that start with
`partial`, deduplicated and in grammar order (first appearance on a depth-first
walk from the start rule). Literals filter by prefix; providers are offered unless
`partial` looks like an option. A partial that starts with a glue prefix yields
that glue's values with `prefix` set. `check()` reports the first word that cannot
belong to any command line; `valid` means the words are a viable prefix.

Both queries are `noexcept` and never allocate: all state lives in the caller's
`match_scratch` (about 140 KiB; allocate it once). Exceeding a limit returns
`match_status::unknown` instead of a guess. Query limits: `max_words` (256),
`max_items` (16384 Earley items), `max_set_items` (1024 per set) and `max_sets`
(1024, words plus decomposed cluster characters). Compile limits: 4096
nonterminals, terminals and distinct candidates, and 65535 grammar slots.

```sh
ctest --preset debug -R '^(Matcher|MatcherCompile|Spec|SpecCompile)\.'
```

The timing benchmark is a disabled test; run it from a Release build:

```sh
cmake --preset release && cmake --build --preset release
./out/release/ebnf_tests --gtest_also_run_disabled_tests --gtest_filter='*Benchmark*'
```

## Other build configurations

Release and sanitizer builds have separate directories. To enable tests explicitly:

```sh
cmake --preset release -DBUILD_TESTING=ON
cmake --build --preset release
ctest --preset release

cmake --preset sanitize
cmake --build --preset sanitize
ctest --preset sanitize
```

The sanitizer preset enables AddressSanitizer and UndefinedBehaviorSanitizer. It
requires GCC or Clang with the GNU-style driver and installed sanitizer runtimes.
On macOS, use upstream LLVM for sanitizer builds. With LLVM on `PATH`, replace
an existing sanitizer configuration's compiler with:

```sh
CXX=clang++ cmake --fresh --preset sanitize
```

To make compiler warnings fail the build:

```sh
cmake --preset debug -DEBNF_WARNINGS_AS_ERRORS=ON
```

## Editor

Configure the Debug preset before opening C++ files. CMake generates
`out/debug/compile_commands.json`, which `.clangd` uses for compiler flags and
include paths. Do not edit or commit the generated database. No symlink is needed.
The other presets generate their own databases without changing the editor's
Debug configuration.

Use `clangd` as the editor's C++ language server and `clang-format` as its C++
formatter. `.editorconfig` sets two-space indentation and LF line endings.
Debug symbols are available in `out/debug/ebnf` for LLDB or GDB.

## Debug in LazyVim

Enable `dap.core` and `lang.clangd` in `:LazyExtras`, restart Neovim, and
check that `codelldb` is installed in `:Mason`. Install it with
`:MasonInstall codelldb` if necessary.

Build and open Neovim from this directory:

```sh
cmake --preset debug
cmake --build --preset debug
nvim tests/parser_test.cpp
```

The working directory must be `lib/ebnf`: nvim-dap reads
`.vscode/launch.json` from the current directory and resolves
`${workspaceFolder}` to it. If Neovim is already open elsewhere, use
`:cd /path/to/telar/lib/ebnf` first.

Set a breakpoint with `<leader>db`, then start with `<leader>dc` and choose:

- `ebnf: main`: launch the executable and stop at `main` using a one-shot
  breakpoint. The current `main` only returns success; use a test profile to
  debug the lexer or parser.
- `ebnf: filtered tests`: enter a GoogleTest filter, such as `Grammar.*`,
  `Lexer.*`, or `Grammar.SingleRuleisAValidSentence`.
- `ebnf: all tests`: run the complete test binary under the debugger.

Test profiles stop on a failed GoogleTest assertion. The DAP UI opens
automatically and shows variables, watches, and the call stack.

| LazyVim key | Action |
| --- | --- |
| `<leader>dO` | Step over |
| `<leader>di` | Step into |
| `<leader>do` | Step out |
| `<leader>de` | Evaluate the expression under the cursor or selection |
| `<leader>dt` | Stop debugging |

Rebuild after changing code, before starting another session. Inside Neovim,
run `:!cmake --build --preset debug`. Launching the debugger does not build
the executable automatically.

## Format and analyze

```sh
cmake --build --preset debug --target format
cmake --build --preset debug --target format-check
cmake --build --preset debug --target lint
```

`format` edits C++ sources, headers and `.cppm` module interfaces. `format-check` reports formatting errors
without changing files. Both skip build directories, generated files, and vendored
code. These commands share TBC's tooling helper. `lint` runs `clang-tidy` on the translation units in the selected build's
compilation database, excluding dependencies and generated code, and fails on
enabled diagnostics. Test sources are included. Build first if sources need
generated headers. Tooling is explicit; normal builds do not run it.

The format follows `src/runtime-cpp/.clang-format`. The tidy configuration
enables the Clang analyzer, bug-prone code, performance, portability, and
modernization checks. It does not enforce trailing return types.

CMake also discovers implementation `.cpp`, `.cc`, and `.cxx` files outside
`tests/` and compiles them into both the executable and the tests. `main.cpp`
remains the executable's explicit entry point and is not included in the tests.
Build directories, vendored dependencies, and generated code are excluded.
Formatting discovers new C++ files automatically; lint follows the CMake targets.
Local preset overrides belong in `CMakeUserPresets.json`, which Git ignores.
