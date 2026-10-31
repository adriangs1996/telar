# ebnf

Standalone C++23 project. Run these commands from `dlls/ebnf`.

## Requirements

- CMake 3.25 or newer and Ninja.
- A compiler with C++23 support.
- Network access for the first test configure, which downloads GoogleTest v1.18.0.
- `clangd`, `clang-format`, and `clang-tidy` on `PATH`. Prefer LLVM tools from the same installation.

On macOS with Homebrew:

```sh
brew install cmake ninja llvm
export PATH="$(brew --prefix llvm)/bin:$PATH"
```

On Linux, install these tools with your package manager. Set `CXX=clang++` or
`CXX=g++` before the first configure to choose a compiler. CMake caches that choice
per build directory.

## Build and test

With Just installed, configure, build, and run tests with GoogleTest colors in one
command. Run from the repository root or `dlls/ebnf`. Extra arguments go to CTest:

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

`lexer.hpp` groups ASCII identifiers, numbers, and quoted literals into tokens.
Whitespace is discarded outside literals and preserved inside them. Both quote
styles are supported; a `String` token contains the literal text without quotes.
The lexer follows the character set in the grammar and requires nonempty literals.
It validates `\n`, `\t`, `\r`, `\f`, `\b`, `\\`, `\'`, and `\"` inside either
quote style. Escaped quotes do not close a literal. Unknown or incomplete escapes
throw `std::invalid_argument`. Token and AST text preserve the original escape
spelling without decoding or allocating new text. Comments are not supported.

`Lexer::tokenizeSourceIntoBuffer` returns the number of tokens written, including
one final `End`. The capacity argument includes that terminator. Invalid input
throws `std::invalid_argument`; insufficient capacity throws `std::length_error`
rather than silently truncating the input. Token text borrows the source storage.

`parser.hpp` consumes complete tokens. `parseIdentifier()` and `parseString()`
return source-backed views; character recognition and whitespace handling belong
to the lexer. Tokenizer implementations must return `std::size_t` and include
`End` in their reported count. `parse()` resets the token cursor before reading.

Run the lexer and parser-boundary tests with:

```sh
ctest --preset debug -R '^(Lexer\.|Grammar\.)'
```

## Parser implementation exercises

`parser.hpp` contains the recursive-descent grammar recognizer. AST construction
below the rule level remains incomplete; the lexer integration does not finish
those exercises. `tests/parser_test.cpp` checks rule recognition and the lexer
boundary, not complete expression trees.

Run the exercises in this order:

1. `ctest --preset debug -R '^PrimaryTest\.'`
2. `ctest --preset debug -R '^Syntax/InvalidPrimaryTest\.'`
3. `ctest --preset debug -R '^(ExpressionTest\.|Operators/AssociativityTest\.|Syntax/InvalidExpressionTest\.)'`
4. `ctest --preset debug -R '^(RuleTest\.|RuleListTest\.|Syntax/InvalidGrammarTest\.)'`

Rebuild with `cmake --build --preset debug` before rerunning tests after an edit.

The initial contract uses explicit commas for concatenation and binary,
left-associative AST nodes. Parentheses return the inner node; brackets and braces
create `Optional` and `ZeroOrMore` nodes with one child. A `Rule` stores its name in
`text` and has one body child. Literal text excludes the surrounding quotes.
Syntax errors throw `std::invalid_argument`, distinct from the unfinished-method
exception, so error tests cannot pass merely because a method is unimplemented.

Identifiers are references, not resolved symbols. Forward references are allowed.
The caller must keep source text alive while the parser and AST text views use it.
Implicit concatenation, postfix operators, exception (`-`), and comments
are outside these initial exercises.

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

The working directory must be `dlls/ebnf`: nvim-dap reads
`.vscode/launch.json` from the current directory and resolves
`${workspaceFolder}` to it. If Neovim is already open elsewhere, use
`:cd /path/to/telar/dlls/ebnf` first.

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

`format` edits C++ sources and headers. `format-check` reports formatting errors
without changing files. Both skip build directories, generated files, and vendored
code. `lint` runs `clang-tidy` on the translation units in the selected build's
compilation database, excluding dependencies and generated code, and fails on
enabled diagnostics. Test sources are included. Build first if sources need
generated headers. Tooling is explicit; normal builds do not run it.

The format follows `services/runtime-cpp/.clang-format`. The tidy configuration
enables the Clang analyzer, bug-prone code, performance, portability, and
modernization checks. It does not enforce trailing return types.

CMake also discovers implementation `.cpp`, `.cc`, and `.cxx` files outside
`tests/` and compiles them into both the executable and the tests. `main.cpp`
remains the executable's explicit entry point and is not included in the tests.
Build directories, vendored dependencies, and generated code are excluded.
Formatting discovers new C++ files automatically; lint follows the CMake targets.
Local preset overrides belong in `CMakeUserPresets.json`, which Git ignores.
