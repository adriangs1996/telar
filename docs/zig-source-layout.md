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
- `packed struct` and `extern struct` may use explicit declarations when their
  layout requires it. This is not an exception for ordinary structs.
- A directory does not require a `root.zig`. Import its declared public files;
  helpers remain internal to their capability. Module entrypoints required by
  `build.zig` remain explicit. Removing directory barrels does not permit
  reverse runtime/client dependencies or access to private capabilities.
- Preserve test discovery when splitting files. Generic tests instantiate the
  family they exercise. File placement does not make struct fields private;
  mutations still follow the owner's capability APIs.

## Migration

The migration starts at `3b801c85` on `refactor/zig-source-layout`. Source layout
changes are separate from the frontend execution-model proposal. Existing
runtime ownership, IPC encodings, resource lifetimes and presentation completion
remain unchanged. Each migrated source and its consumers move together; legacy
aliases are removed rather than kept as a second public interface.
