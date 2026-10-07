const std = @import("std");
const assets_build = @import("assets.zig");
const Application = @import("Application.zig");
const ModuleGraph = @import("ModuleGraph.zig");
const native_libraries = @import("native_libraries.zig");

/// Register portability checks: `cross.add(b)`.
pub fn add(b: *std.Build) *std.Build.Step {
    // Type-checks the whole binary for Linux targets this machine is not, so a
    // runtime that stops compiling there fails on any machine.
    const cross_step = b.step("cross", "Type-check platform-dependent code elsewhere");
    for ([_]std.Target.Query{
        .{ .os_tag = .linux, .cpu_arch = .x86_64, .abi = .gnu },
        .{ .os_tag = .linux, .cpu_arch = .aarch64, .abi = .gnu },
    }) |query| {
        const cross_target = b.resolveTargetQuery(query);
        const natives = native_libraries.portable(b, cross_target, .Debug);
        // Linux ships the whole binary, so the check builds the graph a
        // release builds, emulator included.
        const graph = ModuleGraph.create(b, cross_target, .Debug, natives) orelse return cross_step;
        addBinaryCheck(b, cross_step, graph);
    }

    return cross_step;
}

/// Type-checks the telar executable for `graph`'s target without the native
/// client: the runtime, the shared client and the CLI. The window imports the
/// target's Wayland, Vulkan and xkbcommon headers, which only a Linux host
/// has, so a native Linux build checks it. A runtime that stops compiling on
/// Linux then fails `zig build cross` on any machine.
fn addBinaryCheck(b: *std.Build, step: *std.Build.Step, graph: ModuleGraph) void {
    const modules = graph.modules(
        assets_build.add(b, graph.target, graph.optimize),
        Application.binaryOptions(b, .{
            .native_client = false,
        }),
        false,
    );
    const main = Application.mainModule(b, modules, null);
    const binary = b.addExecutable(.{
        .name = b.fmt("telar-{s}", .{@tagName(graph.target.result.cpu.arch)}),
        .root_module = main,
    });
    step.dependOn(&binary.step);
}
