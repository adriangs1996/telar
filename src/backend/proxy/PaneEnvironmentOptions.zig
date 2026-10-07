const std = @import("std");
const pty = @import("pty");
const Override = pty.Override;

inherited: std.process.Environ,
overrides: []const Override,
