const std = @import("std");
const freetype_build = @import("freetype.zig");
const model_build = @import("model.zig");
const assets_build = @import("assets.zig");
const gui_build = @import("gui.zig");
const Application = @import("Application.zig");
const Coverage = @import("Coverage.zig");
const Libraries = @import("Libraries.zig");
const ModuleGraph = @import("ModuleGraph.zig");
const native_libraries = @import("native_libraries.zig");

/// Register portability checks: `cross.add(b)`.
pub fn add(b: *std.Build) *std.Build.Step {
    // Type-checks platform-dependent client code for targets this machine is
    // not. A Windows implementation that silently stopped compiling would
    // otherwise be
    // invisible until somebody on Windows tried to build - which, for a project
    // developed on one machine, means until a user reports it.
    const cross_step = b.step("cross", "Type-check platform-dependent code elsewhere");
    for ([_]std.Target.Query{
        .{ .os_tag = .windows, .cpu_arch = .x86_64 },
        .{ .os_tag = .linux, .cpu_arch = .x86_64, .abi = .gnu },
        .{ .os_tag = .linux, .cpu_arch = .aarch64, .abi = .gnu },
    }) |query| {
        const cross_target = b.resolveTargetQuery(query);
        const natives = native_libraries.portable(b, cross_target, .Debug);
        var cross_core: *std.Build.Module = undefined;
        var cross_data: *std.Build.Module = undefined;
        var cross_libraries: Libraries = undefined;
        if (query.os_tag.? == .linux) {
            // Linux ships the whole binary, so the check builds the graph a
            // release builds, emulator included.
            const graph = ModuleGraph.create(b, cross_target, .Debug, natives, unmeasured) orelse return cross_step;
            addBinaryCheck(b, cross_step, graph);
            cross_core = graph.core;
            cross_data = graph.data;
            cross_libraries = graph.libraries;
        } else {
            // No emulator is built for this target; the fake width table
            // stands in for the `unicode` library.
            const cross_unicode = b.createModule(.{
                .root_source_file = b.path("lib/unicode/fake.zig"),
                .target = cross_target,
                .optimize = .Debug,
            });
            cross_core = b.createModule(.{
                .root_source_file = b.path("src/core/core.zig"),
                .target = cross_target,
                .optimize = .Debug,
            });
            cross_libraries = Libraries.create(b, cross_target, .Debug, &.{
                .{
                    .name = "unicode",
                    .module = cross_unicode,
                },
                .{
                    .name = "freetype",
                    .module = freetype_build.add(b, .{ .target = cross_target, .optimize = .Debug, .disable_coverage = false }),
                },
            }, natives);
            cross_libraries.addImports(cross_core);
            cross_data = model_build.create(b, cross_core, cross_libraries);
        }

        cross_libraries.addChecks(b, cross_step, cross_target);
        // Host services the client runs on every platform: sound, system
        // notices and the local clock.
        for ([_][]const u8{
            "src/client/agents/sound_playback.zig",
            "src/client/notifications/system_notification.zig",
            "src/client/resources/local_time.zig",
        }) |path| {
            const service_check = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(path),
                    .target = cross_target,
                    .optimize = .Debug,
                    .link_libc = true,
                }),
            });
            service_check.root_module.addImport("telar-core", cross_core);
            service_check.root_module.addImport("model", cross_data);
            if (query.os_tag.? == .windows) {
                service_check.root_module.linkSystemLibrary("user32", .{});
            }

            cross_step.dependOn(&service_check.step);
        }
    }
    return cross_step;
}

/// Cross checks instrument nothing.
const unmeasured: Coverage = .{
    .enabled = false,
    .runtime_path = null,
};

/// Type-checks the whole telar executable for `graph`'s target: the runtime,
/// the client, the CLI and the native client's Zig code. Nothing is emitted
/// or linked, so the window's C sources and the system headers they need
/// (Wayland, Vulkan, Fontconfig) stay out; the Zig that calls them does not.
/// A runtime that stops compiling on Linux then fails `zig build cross` on
/// any machine.
fn addBinaryCheck(b: *std.Build, step: *std.Build.Step, graph: ModuleGraph) void {
    const modules = graph.modules(
        assets_build.add(b, graph.target, graph.optimize),
        Application.binaryOptions(b, .{
            .native_client = true,
        }),
        true,
    );
    const main = Application.mainModule(b, modules, null);
    // The Mermaid helper is a Rust build for the host; only its path is
    // compiled in.
    main.addImport("telar-gui", gui_build.zigModule(b, modules, b.path("tools/diagram-renderer")));
    const binary = b.addExecutable(.{
        .name = b.fmt("telar-{s}", .{@tagName(graph.target.result.cpu.arch)}),
        .root_module = main,
    });
    step.dependOn(&binary.step);
}
