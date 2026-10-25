const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const ghostty = builder.dependency("ghostty_vt", .{ .target = target, .optimize = optimize }).module("ghostty-vt");
    const keyinput = builder.createModule(.{ .root_source_file = builder.path("lib/keyinput/root.zig"), .target = target, .optimize = optimize });
    const core = builder.createModule(.{ .root_source_file = builder.path("src/core/core.zig"), .target = target, .optimize = optimize });
    core.addImport("keyinput", keyinput);
    const root = builder.createModule(.{ .root_source_file = builder.path("oracle.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("ghostty-vt", ghostty);
    root.addImport("telar-core", core);
    const library = builder.addLibrary(.{ .name = "screen-reference", .linkage = .dynamic, .root_module = root });
    builder.installArtifact(library);
}
