const CreateTabResult = @This();
const workspace_mod = @import("../../../workspace/root.zig");
const source_namespace = @import("create_tab.zig");
created: workspace_mod.TabCreated,
root_pane_id: source_namespace.schema.PaneId,
