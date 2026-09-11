const Applied = @This();
const source_namespace = @import("pane_graphics.zig");
const client_model = @import("../../root.zig").model;
pane_id: source_namespace.schema.PaneId,
fallback: ?client_model.PaneGraphicsFallbackCommit,
