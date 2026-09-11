# Zig source layout

These rules apply to first-party Zig sources, including tests, examples,
benchmarks, build support and linters. Dependency sources and generated files
retain their upstream layout.

- A concrete struct owns a PascalCase file. The file is the struct: fields and
  methods live at file scope and its self type is `@This()`. Named ordinary
  structs are not declared at file scope inside another file. Auxiliary state
  and options types have their own files too.
- A namespace of functions, enums, unions and constants uses snake_case.
- A generic family owns `GenericName.zig`. Its only public file-level function
  is `Type(...) type`. Methods belong to the returned type; private helpers and
  tests are allowed. The constructor's signature follows the existing function
  style rules.
- Import generic constructors directly, retaining the prefix:

  ```zig
  const GenericRouter = @import("GenericRouter.zig").Type;
  const InputRouter = GenericRouter(Action, limits, Decoder);
  ```

  Specialized types use concrete names. Do not alternate this convention with
  importing the factory namespace and calling `GenericRouter.Type(...)`.
- `packed struct` and `extern struct` use one explicit layout declaration per
  dedicated PascalCase file. Preserve ABI names, field order, widths and
  alignment. This is not an exception for ordinary structs.
- A directory does not require a `root.zig`. Import its declared public files;
  helpers remain internal to their capability. Module entrypoints required by
  `build.zig` remain explicit. Removing directory barrels does not permit
  reverse runtime/client dependencies or access to private capabilities.
- Preserve declarations read through `@hasDecl`, `@field` or namespace ports.
  Root diagnostic flags and delivery hooks are contracts even without ordinary
  call-site references; a forwarding declaration is not automatically obsolete.
- Preserve test discovery when splitting files. Generic tests instantiate the
  family they exercise. File placement does not make struct fields private;
  mutations still follow the owner's capability APIs.

## Enforcement

`zig build codestyle` checks all maintained source directories using `std.zig.Ast`.
It retains the existing signature and conditional rules. `zig build test` and
`zig build check` run the same checks without fixing files. A file's category
comes from declarations, not text inside comments, strings or value literals.
Generic methods are not additional file-level constructors.

`src/client/capabilities.json` admits public files independently of filenames.
`zig build check-client-boundaries` rejects reverse modules, undeclared owners,
private cross-capability imports, incorrect casing and source aliases. Its
assembly list is for entrypoint test discovery, not a general public API.

Tests can live with a type or in a behavior-focused namespace. Explicit test
imports in package entrypoints retain discovery after removing barrels.
`tools/compare_zig_tests.py` compares metadata from verbose native builds;
missing named tests fail, while reduced duplicate execution is reported.

## Migration boundary

The migration starts at `3b801c85` on `refactor/zig-source-layout`. It changes
source organization, not frontend scheduling, runtime ownership, IPC encodings,
resource lifetimes or presentation completion. Types and their consumers move
together; obsolete aliases are not a second public interface.

Historical ADRs, plans and benchmark reports retain paths from their recorded
revision. The [capability map](capabilities.md) and flow documents describe the
current tree.

The [migration validation report](validation/zig-source-layout/README.md) records
source, test-discovery and executable checks. Performance acceptance remains
open.
