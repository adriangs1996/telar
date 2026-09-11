const DismissEffects = @This();
const attachments = @import("../../attachments/root.zig");
const RemovalCommand = @import("RemovalCommand.zig");
context: *anyopaque,
plan: *const fn (*anyopaque, attachments.Id) ?RemovalCommand,
deliver: *const fn (*anyopaque, RemovalCommand) anyerror!void,
remove: *const fn (*anyopaque, attachments.Id) ?bool,
