const std = @import("std");
const Application = @import("Application.zig");

/// Register packaging for the selected target: `packaging.add(b, app)`.
pub fn add(b: *std.Build, app: Application) void {
    // Application packaging. The shipped binary is the same `telar`; a bundle
    // adds a launcher that runs `telar gui --login-shell`, and a desktop file
    // does the same on Linux. See docs/packaging.md.
    if (app.modules.target.result.os.tag == .macos) {
        const launcher = b.addExecutable(.{
            .name = "Telar",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/launcher/main.zig"),
                .target = app.modules.target,
                .optimize = app.modules.optimize,
            }),
        });
        const bundle_step = b.step("bundle", "Assemble zig-out/Telar.app");
        const contents = "Telar.app/Contents";
        // Case-folding file systems cannot hold `Telar` and `telar` side by side.
        bundle_step.dependOn(&b.addInstallArtifact(app.exe, .{ .dest_dir = .{ .override = .{ .custom = contents ++ "/Resources/bin" } } }).step);
        bundle_step.dependOn(&b.addInstallArtifact(launcher, .{ .dest_dir = .{ .override = .{ .custom = contents ++ "/MacOS" } } }).step);
        bundle_step.dependOn(&b.addInstallFile(b.path("packaging/macos/Info.plist"), contents ++ "/Info.plist").step);
        bundle_step.dependOn(&b.addInstallFile(b.path("packaging/macos/telar.icns"), contents ++ "/Resources/telar.icns").step);

        const dmg = b.addSystemCommand(&.{
            "hdiutil",    "create",
            "-volname",   "Telar",
            "-srcfolder", b.getInstallPath(.prefix, "Telar.app"),
            "-ov",        "-format",
            "UDZO",       b.getInstallPath(.prefix, "Telar.dmg"),
        });
        dmg.step.dependOn(bundle_step);
        b.step("dmg", "Build zig-out/Telar.dmg from the bundle").dependOn(&dmg.step);
    } else if (app.modules.target.result.os.tag == .linux) {
        const desktop = b.addInstallFile(b.path("packaging/linux/telar.desktop"), "share/applications/telar.desktop");
        const icon = b.addInstallFile(b.path("packaging/linux/telar.png"), "share/icons/hicolor/512x512/apps/telar.png");
        b.getInstallStep().dependOn(&desktop.step);
        b.getInstallStep().dependOn(&icon.step);

        const archive_name = b.fmt("telar-{s}-linux.tar.gz", .{@tagName(app.modules.target.result.cpu.arch)});
        const archive = b.addSystemCommand(&.{ "tar", "-czf", b.getInstallPath(.prefix, archive_name), "-C", b.install_path, "bin", "share" });
        archive.step.dependOn(b.getInstallStep());
        b.step("package-linux", "Build zig-out/telar-<arch>-linux.tar.gz with the binary, desktop entry and icon").dependOn(&archive.step);
    }
}
