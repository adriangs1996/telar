const std = @import("std");
const OverrideType = @import("../pty/Override.zig");
const PaneEnvironmentOptions = @This();

inherited: std.process.Environ,
overrides: []const OverrideType,
