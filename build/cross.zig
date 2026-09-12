const std = @import("std");
const lua_build = @import("lua.zig");
const freetype_build = @import("freetype.zig");
const assets_build = @import("assets.zig");
const client_build = @import("client.zig");

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
        // Platform code publishes shared client values such as `LocalTime`, and
        // sound policy is shared configuration, so both checks need the client
        // module and, through it, the vendored Lua for that target.
        const cross_lua_api = lua_build.add(b, .{
            .target = cross_target,
            .optimize = .Debug,
            .name = b.fmt("lua-{s}-{s}", .{ @tagName(query.os_tag.?), @tagName(query.cpu_arch.?) }),
        });
        const cross_telar_lua = b.createModule(.{
            .root_source_file = b.path("src/lua/lua.zig"),
            .target = cross_target,
            .optimize = .Debug,
            .link_libc = true,
        });
        cross_telar_lua.addImport("lua-api", cross_lua_api);
        const cross_client = client_build.add(b, cross_core, .{ .api = cross_lua_api, .telar = cross_telar_lua });
        const check = b.addObject(.{
            .name = b.fmt("platform-{s}-{s}", .{ @tagName(query.os_tag.?), @tagName(query.cpu_arch.?) }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/platform/platform.zig"),
                .target = cross_target,
                .optimize = .Debug,
            }),
        });
        check.root_module.addImport("telar-client", cross_client);
        cross_step.dependOn(&check.step);
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
        const sound_check = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/sound/sound_tests.zig"),
                .target = cross_target,
                .optimize = .Debug,
                .link_libc = true,
            }),
        });
        sound_check.root_module.addImport("telar-core", cross_core);
        sound_check.root_module.addImport("telar-client", cross_client);
        if (query.os_tag.? == .windows) {
            sound_check.root_module.linkSystemLibrary("user32", .{});
        }
        cross_step.dependOn(&sound_check.step);
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
