const std = @import("std");
const Application = @import("Application.zig");

/// The headless client for tests and tools: `zig build headless` installs
/// `telar-headless`. It is not part of `zig build`, the bundle or the
/// packages. Returns its module so the test suite can run its tests.
pub fn add(b: *std.Build, app: Application) *std.Build.Module {
    const modules = app.modules;
    const headless = b.createModule(.{
        .root_source_file = b.path("src/headless/headless.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
        .link_libc = true,
    });
    headless.addImport("telar-client", modules.client);
    headless.addImport("model", modules.data);
    headless.addImport("telar-core", modules.core);
    modules.libraries.addImports(headless);

    const root = b.createModule(.{
        .root_source_file = b.path("src/headless_main.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
        .link_libc = true,
    });
    root.addImport("telar-headless", headless);
    root.addImport("telar-client", modules.client);
    root.addImport("model", modules.data);
    root.addImport("telar-core", modules.core);
    root.addOptions("build_options", modules.build_options);
    modules.libraries.addImports(root);

    const exe = b.addExecutable(.{
        .name = "telar-headless",
        .root_module = root,
    });
    b.step("headless", "Build the headless client for tests and tools").dependOn(&b.addInstallArtifact(exe, .{}).step);
    return headless;
}
