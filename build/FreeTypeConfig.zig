const std = @import("std");
const FreeTypeConfig = @This();

target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
disable_coverage: bool,
