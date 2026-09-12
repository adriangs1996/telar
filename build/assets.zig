const std = @import("std");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/assets/assets.zig"),
        .target = target,
        .optimize = optimize,
    });
}
