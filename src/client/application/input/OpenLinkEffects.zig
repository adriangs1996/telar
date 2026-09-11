const Effects = @This();
const link_capability = @import("../../links/root.zig");
context: *anyopaque,
open_file: *const fn (*anyopaque, link_capability.FilePath) anyerror!void,
open_external: *const fn (*anyopaque, link_capability.Target) anyerror!void,
