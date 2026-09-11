---
status: accepted
---

# Make Zig type files explicit

Concrete structs use the file's implicit struct in a PascalCase file. A generic
family owns `GenericName.zig` and exports one public `Type` constructor, imported
as `const GenericName = @import("GenericName.zig").Type;`. Function, enum and union
namespaces use snake_case. Explicit packed and extern layouts remain permitted.

This replaces the mandatory per-directory roots from ADR 0002 with declared
public file entries. It makes type ownership visible without forwarding through
chains of directory barrels. Module entrypoints, private capability boundaries
and the runtime/client dependency direction remain necessary. The migration
must preserve test discovery and compiled behavior; it does not authorize a
concurrent frontend execution rewrite.
