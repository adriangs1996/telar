const TabSelectionType = @import("../../model/TabSelection.zig");
const SelectionEffects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, TabSelectionType) anyerror!void,
