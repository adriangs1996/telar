const PaneIdType = @import("telar-core").PaneId;
const Effects = @This();

context: *anyopaque,
clear_graphics: *const fn (*anyopaque, PaneIdType) void,
