const RenameRequestEffects = @This();
const RequestedRename = @import("RequestedRename.zig");
context: *anyopaque,
send: *const fn (*anyopaque, RequestedRename) anyerror!void,
