const FreeTypeConfig = @This();
const std = @import("std");
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
disable_coverage: bool,
