const Sources = @This();
const agents_module = @import("../agents/root.zig");
const source_namespace = @import("goto_picker.zig");
agents: *const agents_module.Snapshot,
workspaces: *const source_namespace.workspace_list.Snapshot,
tabs: ?*const source_namespace.tabs_mod.Model,
