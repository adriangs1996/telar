const types = @import("../../attachments/types.zig");
const RemovalCommand = @import("RemovalCommand.zig");
const DismissEffects = @This();

context: *anyopaque,
plan: *const fn (*anyopaque, types.Id) ?RemovalCommand,
deliver: *const fn (*anyopaque, RemovalCommand) anyerror!void,
remove: *const fn (*anyopaque, types.Id) ?bool,
