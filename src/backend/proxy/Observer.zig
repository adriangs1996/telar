const Observer = @This();
const std = @import("std");
const Event = @import("MiddlewareEvent.zig");
context: *anyopaque,
observe: *const fn (*anyopaque, std.Io, Event) void,
