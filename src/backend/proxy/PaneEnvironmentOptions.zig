const std = @import("std");
const Override = @import("../pty/Override.zig");
const PaneEnvironmentOptions = @This();

inherited: std.process.Environ,
overrides: []const Override,
