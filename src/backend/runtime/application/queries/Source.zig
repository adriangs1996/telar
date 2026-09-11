const TabLocationType = @import("telar-core").TabLocation;
const Source = @This();

context: *anyopaque,
contains_tab: *const fn (*anyopaque, TabLocationType) bool,
running_panes: *const fn (*anyopaque, TabLocationType) u16,
