const PaneIdType = @import("telar-core").PaneId;
const Completion = @This();

detach_pane: ?PaneIdType = null,
close_client: bool = false,
stopping_delivered: bool = false,
