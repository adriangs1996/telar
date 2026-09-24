const std = @import("std");
const pty = @import("pty");
const Override = pty.Override;
const PaneEnvironmentOptions = @This();

inherited: std.process.Environ,
overrides: []const Override,
