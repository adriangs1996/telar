const TransformContext = @This();
const source_namespace = @import("middleware.zig");
const dialect_mod = @import("provider/dialect.zig");
pane_id: source_namespace.schema.PaneId,
pane_generation: u64,
dialect: dialect_mod.ApiDialect,
protocol: source_namespace.Protocol,
direction: source_namespace.Direction,
kind: source_namespace.HeaderKind,
connection_id: u64,
stream_id: u32,
