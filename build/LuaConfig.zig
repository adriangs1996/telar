const std = @import("std");
const LuaConfig = @This();

target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
name: []const u8,
