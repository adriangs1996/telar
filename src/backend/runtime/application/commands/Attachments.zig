const Attachments = @This();
const source_namespace = @import("detach_pane.zig");
const attachment_mod = @import("../../attachment/root.zig");
context: *anyopaque,
detach: *const fn (*anyopaque, source_namespace.schema.PaneId) ?attachment_mod.PaneDetached,
leave_workspace: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) bool,
