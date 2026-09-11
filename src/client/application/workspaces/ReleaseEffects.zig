const ReleaseEffects = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_transition_delivery.zig");
context: *anyopaque,
remember_bookmark: *const fn (*anyopaque, client_model.WorkspaceBookmark) void,
clear_pane_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
