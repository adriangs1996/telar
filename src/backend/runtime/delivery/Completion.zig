const core = @import("telar-core");
const Completion = @This();

detach_pane: ?core.PaneId = null,
close_client: bool = false,
stopping_delivered: bool = false,
