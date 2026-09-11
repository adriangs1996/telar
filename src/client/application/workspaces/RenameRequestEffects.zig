const RequestedRename = @import("RequestedRename.zig");
const RenameRequestEffects = @This();

context: *anyopaque,
send: *const fn (*anyopaque, RequestedRename) anyerror!void,
