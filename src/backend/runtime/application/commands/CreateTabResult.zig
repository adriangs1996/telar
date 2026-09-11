const TabCreatedType = @import("../../../workspace/TabCreated.zig");
const PaneIdType = @import("telar-core").PaneId;
const CreateTabResult = @This();

created: TabCreatedType,
root_pane_id: PaneIdType,
