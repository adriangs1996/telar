const LuaConfig = @This();
const std = @import("std");
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
name: []const u8,
