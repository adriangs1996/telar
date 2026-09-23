# Zig source layout

These rules apply to first-party Zig sources, including tests, benchmarks,
build support and linters. Dependency sources and generated files keep their
upstream layout. Names follow [naming](naming.md).

- A public struct owns a PascalCase file, and the file is the struct: fields
  and methods live at file scope and the self type is `@This()`. Tables
  (`Panes.zig`) and the process models (`ClientModel.zig`) follow this rule.
- A helper struct, enum, union or packed/extern layout that only one file
  uses stays private in that file. It moves to its own file when a second
  file needs it by name.
- A standalone public enum or union owns a PascalCase file with one named
  declaration matching the filename.
- Procedures live in snake_case files named after their flow
  (`pane_frame.zig`).
- A generic family owns `GenericName.zig` whose only public file-level
  function is `Type(...) type`. Import it as
  `const GenericRouter = @import("GenericRouter.zig").Type;`.
- A public packed or extern struct keeps one layout declaration per file and
  preserves ABI names, field order, widths and alignment.
- Import a module once and qualify its members (`core.TabCreated`). Import a
  type under its own name, never as `*Type`, and never inline an `@import`.
- Explicit test imports in package entrypoints keep test discovery working
  when files move.
- Declarations read through `@hasDecl`, `@field` or root diagnostic hooks are
  contracts even without ordinary references.

## Enforcement

`zig build codestyle` checks these rules with `std.zig.Ast`, together with
receiver names (a method's receiver is `self`, a `ClientModel` or
`RuntimeModel` parameter is `model`) and inline imports, and fixes what it
can with `-- --fix`; `zig build test` and `zig build check` run it without
fixing. A file's category comes from its declarations, not from comments or
strings. `zig build check-client-boundaries` and
`zig build check-model-boundaries` keep module dependencies pointing the right
way.
