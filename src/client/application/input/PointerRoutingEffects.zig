const PointerCommandType = @import("PointerCommand.zig");
const ViewOutcome = @import("ViewOutcome.zig");
const Effects = @This();

context: *anyopaque,
copy_mode: *const fn (*anyopaque, PointerCommandType) anyerror!bool,
view: *const fn (*anyopaque, PointerCommandType) anyerror!ViewOutcome,
link: *const fn (*anyopaque, PointerCommandType) anyerror!bool,
pane: *const fn (*anyopaque, PointerCommandType) anyerror!void,
