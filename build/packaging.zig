const std = @import("std");
const Application = @import("Application.zig");
const manifest = @import("../build.zig.zon");

/// Register packaging for the selected target: `packaging.add(b, app, diagram_helper)`.
pub fn add(b: *std.Build, app: Application, diagram_helper: ?std.Build.LazyPath) void {
    // Application packaging. The shipped binary is the same `telar`; a bundle
    // adds a launcher that runs `telar gui --login-shell`, and a desktop file
    // does the same on Linux. See docs/packaging.md.
    installNativeLicenses(b, b.getInstallStep(), "share/telar/licenses");
    if (!app.modules.native_client) {
        addLinuxArchive(b, app, "headless-");
        return;
    }

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
        bundle_step.dependOn(&b.addInstallFile(diagram_helper.?, contents ++ "/Resources/bin/telar-diagram-renderer").step);
        bundle_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path("tools/diagram-renderer/licenses"),
            .install_dir = .prefix,
            .install_subdir = contents ++ "/Resources/licenses/diagram-renderer",
        }).step);
        bundle_step.dependOn(&b.addInstallArtifact(launcher, .{ .dest_dir = .{ .override = .{ .custom = contents ++ "/MacOS" } } }).step);
        const info = b.addConfigHeader(
            .{
                .style = .{ .autoconf_at = b.path("packaging/macos/Info.plist.in") },
                .include_path = "Info.plist",
            },
            .{
                .VERSION = manifest.version,
            },
        );
        bundle_step.dependOn(&b.addInstallFile(info.getOutputFile(), contents ++ "/Info.plist").step);
        bundle_step.dependOn(&b.addInstallFile(b.path("packaging/macos/telar.icns"), contents ++ "/Resources/telar.icns").step);
        bundle_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path("tools/syntax-highlighter/licenses"),
            .install_dir = .prefix,
            .install_subdir = contents ++ "/Resources/licenses/syntax-highlighter",
        }).step);
        installNativeLicenses(b, bundle_step, contents ++ "/Resources/licenses");

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
        addLinuxArchive(b, app, "");
    }
}

fn addLinuxArchive(b: *std.Build, app: Application, variant: []const u8) void {
    if (app.modules.target.result.os.tag != .linux) {
        return;
    }

    const archive_name = b.fmt("telar-{s}{s}-linux.tar.gz", .{ variant, @tagName(app.modules.target.result.cpu.arch) });
    const archive = b.addSystemCommand(&.{ "tar", "-czf", b.getInstallPath(.prefix, archive_name), "-C", b.install_path, "bin", "share" });
    archive.step.dependOn(b.getInstallStep());
    b.step("package-linux", "Build zig-out/telar-[headless-]<arch>-linux.tar.gz with the binary, desktop entry and icon").dependOn(&archive.step);
}

/// Notices of the C libraries compiled into `telar`, which their licenses
/// require copies of the binary to carry.
fn installNativeLicenses(b: *std.Build, step: *std.Build.Step, root: []const u8) void {
    const notices = [_]struct { dependency: []const u8, file: []const u8 }{
        .{
            .dependency = "brotli",
            .file = "LICENSE",
        },
        .{
            .dependency = "nghttp2",
            .file = "COPYING",
        },
        .{
            .dependency = "freetype",
            .file = "LICENSE.TXT",
        },
        .{
            .dependency = "freetype",
            .file = "docs/FTL.TXT",
        },
        .{
            .dependency = "harfbuzz",
            .file = "COPYING",
        },
    };
    for (notices) |notice| {
        const source = b.dependency(notice.dependency, .{}).path(notice.file);
        const destination = b.fmt("{s}/{s}/{s}", .{ root, notice.dependency, notice.file });
        step.dependOn(&b.addInstallFile(source, destination).step);
    }
}
