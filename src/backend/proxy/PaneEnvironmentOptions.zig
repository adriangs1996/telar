const PaneEnvironmentOptions = @This();
const std = @import("std");
const pty = @import("../pty/root.zig");
inherited: std.process.Environ,
overrides: []const pty.ChildEnvironment.Override,
