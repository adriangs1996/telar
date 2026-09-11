const RenameRequestEffects = @This();
const TabRenameIntent = @import("TabRenameIntent.zig");
context: *anyopaque,
send: *const fn (*anyopaque, TabRenameIntent) anyerror!void,
