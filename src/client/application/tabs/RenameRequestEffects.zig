const TabRenameIntent = @import("TabRenameIntent.zig");
const RenameRequestEffects = @This();

context: *anyopaque,
send: *const fn (*anyopaque, TabRenameIntent) anyerror!void,
