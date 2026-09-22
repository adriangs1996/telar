const core = @import("telar-core");
const PaneSet = @This();

ids: []const core.PaneId,
focused: core.PaneId,
