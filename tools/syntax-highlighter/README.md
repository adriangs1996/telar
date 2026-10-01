# Native syntax highlighting

Telar links this Rust static library into the native adapter. It uses
[tree-sitter-highlight](https://docs.rs/tree-sitter-highlight/0.26.10/tree_sitter_highlight/)
and upstream grammar crates, not handwritten language lexers. The shared client
keeps only syntax roles, styles and extension detection.

`Cargo.toml` pins direct dependencies and `Cargo.lock` pins the full graph.
`vendor/` contains their source and licenses. `.cargo/config.toml` redirects
Cargo to that directory. Normal Zig builds invoke Cargo with `--locked --offline`;
Rust and a C compiler must already be installed. Supported build targets are
macOS/Linux on aarch64/x86_64; cross compilation also needs the matching Rust
target and C toolchain. Only native macOS has been verified for this prototype.

Run `zig build test-syntax-highlighter` from the repository root. For standalone
development, run `cargo test --locked --offline --target-dir /tmp/telar-syntax-dev`
here. Keep generated Cargo output outside this directory, whose files are tracked
as Zig build inputs.

To update dependencies, change the exact versions, regenerate the lockfile with
registry access, run `cargo vendor vendor` from a temporary copy without the
source replacement configuration, and copy the resulting vendor directory back.
Preserve upstream license notices and run the Rust and GUI suites before updating.
Installed notices are collected in `licenses/`; refresh them from every vendored
package's license files when updating dependencies.

## Languages

The original Zig, Ruby, Python, JavaScript/JSX, TypeScript/TSX, JSON, Rust and
Bash grammars are joined by:

| Language | Extensions | Grammar crate |
| --- | --- | --- |
| Go | `.go` | `tree-sitter-go` 0.25.0 |
| C# | `.cs`, `.csx` | `tree-sitter-c-sharp` 0.23.5 |
| Java | `.java` | `tree-sitter-java` 0.23.5 |
| Kotlin | `.kt`, `.kts` | `tree-sitter-kotlin-sg` 0.4.1 |
| Swift | `.swift` | `tree-sitter-swift` 0.7.3 |
| C | `.c`, `.h` | `tree-sitter-c` 0.24.2 |
| C++ | `.cc`, `.cpp`, `.cxx`, `.c++`, `.C`, `.hh`, `.hpp`, `.hxx`, `.h++`, `.H` | `tree-sitter-cpp` 0.23.4 |
| Objective-C | `.m` | `tree-sitter-objc` 3.0.2 |

Detection is case-sensitive. Ambiguous `.h` headers default to C; no repository
scan or content heuristic runs during painting. Objective-C++ `.mm` is not yet
supported. Kotlin uses the ast-grep fork, which exports a compatible grammar
and its own bundled highlight query. Its query retains the upstream Apache
notice separately from the grammar's MIT license.

## Boundary and ownership

`telar_syntax_highlight` takes borrowed UTF-8 source and a caller-owned span buffer.
It returns status, count, byte offsets and static capture-name pointers. No source
or destination pointer is retained. Colors never cross the ABI. Panic unwinding
is caught at the Rust boundary. Invalid input, cancellation and capacity failure
return errors; consumers publish only a fully validated successful result.

Calls run on the GUI observation worker, never during painting or input forwarding.
The source cap is 256 KiB, the same as `syntaxhl.limits.source_bytes`; event
nesting is bounded, and cancellation is requested after 100 ms per parse.
Queries are initialized once and retained. These limits do not constitute a
hard heap quota for the underlying Rust/C libraries.

Highlight queries ship with the grammars. TypeScript combines its query with
JavaScript; JSX/TSX adds the upstream JSX query. Zig's query requires two small
compatibility adaptations: its three `lua-match?` patterns are also valid regular
expressions and become `match?`; the Neovim-only `@spell` directive is removed so
it cannot supersede the comment capture under Tree-sitter's last-match policy.
Swift also removes the editor-only `@spell` capture. C++ and Objective-C prepend
the upstream C query to honor their query inheritance. Older capture names such
as `conditional`, `include`, `storageclass` and `character` map onto existing
Telar roles. Query patterns with unsupported editor predicates are disabled,
instead of letting those predicates become unconditional matches. This skips
Objective-C's `has-ancestor?` struct-property refinement; other captures remain
available. Vendored sources remain unmodified. Tests cover these adaptations
and require keyword, string, number and comment captures for every added language.

This is syntax analysis, not a language server. A parameter reference is only
classified if its upstream query/local analysis supplies that capture. Parsing
a diff hunk cannot recover omitted multiline context; full review must provide
immutable complete before/after contents.
