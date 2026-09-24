const std = @import("std");
const freetype_build = @import("freetype.zig");
const assets_build = @import("assets.zig");
const model_build = @import("model.zig");
const Libraries = @import("Libraries.zig");

/// Register portability checks: `cross.add(b)`.
pub fn add(b: *std.Build) *std.Build.Step {
    // Type-checks platform-dependent frontend code for targets this machine is
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
        const cross_unicode = b.createModule(.{
            .root_source_file = b.path("src/core/unicode_fake.zig"),
            .target = cross_target,
            .optimize = .Debug,
        });
        const cross_core = b.createModule(.{
            .root_source_file = b.path("src/core/core.zig"),
            .target = cross_target,
            .optimize = .Debug,
        });
        cross_core.addImport("unicode", cross_unicode);
        const cross_libraries = Libraries.create(b, cross_target, .Debug);
        const cross_data = model_build.create(b, cross_core);
        cross_libraries.addChecks(b, cross_step, cross_target);
        const raster_check = b.addLibrary(.{
            .name = b.fmt("text-rasterizer-{s}-{s}", .{ @tagName(query.os_tag.?), @tagName(query.cpu_arch.?) }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/graphics/rasterizer_support.zig"),
                .target = cross_target,
                .optimize = .Debug,
                .link_libc = true,
            }),
            .linkage = .static,
        });
        raster_check.root_module.addImport(
            "freetype",
            freetype_build.add(b, .{ .target = cross_target, .optimize = .Debug, .disable_coverage = false }),
        );
        raster_check.root_module.addImport("assets", assets_build.add(b, cross_target, .Debug));
        cross_step.dependOn(&raster_check.step);
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

        if (query.os_tag.? == .linux) {
            // Compile the tests so their calls analyze listener bodies too.
            // An object containing only unused public functions misses errors.
            const local_transport_check = b.addTest(.{
                .name = b.fmt("local-transport-linux-{s}", .{@tagName(query.cpu_arch.?)}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/backend/transport/local.zig"),
                    .target = cross_target,
                    .optimize = .Debug,
                    .link_libc = true,
                }),
            });
            local_transport_check.root_module.addImport("telar-core", cross_core);
            cross_step.dependOn(&local_transport_check.step);
        }
    }
    return cross_step;
}
