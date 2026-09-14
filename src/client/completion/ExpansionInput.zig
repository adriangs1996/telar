const std = @import("std");
const Input = @This();

/// The typed directory as written by the user.
text: []const u8,
environ: std.process.Environ,
/// Absolute directory relative paths resolve against, usually the focused
/// pane's cwd; empty when the client does not know it.
base: []const u8,
