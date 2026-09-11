const RemovalDelivery = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("close_tab.zig");
context: *anyopaque,
deliver: *const fn (*anyopaque, client_model.TabRemovalCommit, ?source_namespace.schema.WorkspaceId) anyerror!source_namespace.TabRemovalDirective,
