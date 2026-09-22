const core = @import("telar-core");
const TabCreatedType = @import("../../../workspace/TabCreated.zig");
const CreateTabResult = @This();

created: TabCreatedType,
root_pane_id: core.PaneId,

kind: core.PaneKind = .terminal,
pane_generation: u64 = 0,
