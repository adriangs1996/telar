const IncrementalComposition = @This();
const Model = @import("telar-client").workspace.multiplexer.Model;
const source_namespace = @import("multiplexer.zig");
const CopyProjection = @import("telar-client").workspace.multiplexer.CopyProjection;
model: *const Model,
screen: *source_namespace.term.Screen,
target: *source_namespace.ui.Buffer,
previous_copy: ?CopyProjection,
copy_changed: bool,
