const Update = @This();
const source_namespace = @import("client_layout_store.zig");
const Sources = @import("Sources.zig");
identity: source_namespace.schema.ClientIdentity,
layout: source_namespace.schema.ClientLayoutUpdateView,
sources: Sources,
