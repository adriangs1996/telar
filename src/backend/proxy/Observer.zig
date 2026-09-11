const std = @import("std");
const MiddlewareEvent = @import("MiddlewareEvent.zig");
const Observer = @This();

context: *anyopaque,
observe: *const fn (*anyopaque, std.Io, MiddlewareEvent) void,
