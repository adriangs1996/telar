const std = @import("std");
const Application = @import("Application.zig");

/// Build the isolated Mermaid helper: `const helper = diagram_renderer.add(b, app)`.
pub fn add(b: *std.Build, app: Application) ?std.Build.LazyPath {
    const target = app.modules.target.result;
    if (target.os.tag != .macos and target.os.tag != .linux) {
        return null;
    }

    const architecture = switch (target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @panic("The diagram helper currently supports aarch64 and x86_64 GUI targets"),
    };
    const platform = if (target.os.tag == .macos) "apple-darwin" else if (target.abi == .musl) "unknown-linux-musl" else "unknown-linux-gnu";
    const triple = b.fmt("{s}-{s}", .{ architecture, platform });
    const build_helper = b.addSystemCommand(&.{ "cargo", "build", "--quiet", "--locked", "--release", "--target", triple, "--manifest-path" });
    build_helper.addFileArg(b.path("tools/diagram-renderer/Cargo.toml"));
    build_helper.addArg("--target-dir");
    const output = build_helper.addOutputDirectoryArg("diagram-renderer");
    addInputs(b, build_helper);
    const helper = output.path(b, b.fmt("{s}/release/telar-diagram-renderer", .{triple}));
    const install = b.addInstallFileWithDir(helper, .bin, "telar-diagram-renderer");
    b.getInstallStep().dependOn(&install.step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("tools/diagram-renderer/licenses"),
        .install_dir = .prefix,
        .install_subdir = "share/telar/diagram-renderer/licenses",
    }).step);

    const test_helper = b.addSystemCommand(&.{ "cargo", "test", "--quiet", "--locked", "--release", "--manifest-path" });
    test_helper.addFileArg(b.path("tools/diagram-renderer/Cargo.toml"));
    test_helper.addArg("--target-dir");
    _ = test_helper.addOutputDirectoryArg("diagram-renderer-tests");
    addInputs(b, test_helper);
    b.step("test-diagram-renderer", "Validate isolated Mermaid parsing, pixels and resource bounds").dependOn(&test_helper.step);
    return helper;
}

fn addInputs(b: *std.Build, run: *std.Build.Step.Run) void {
    const root = "tools/diagram-renderer";
    var directory = b.build_root.handle.openDir(b.graph.io, root, .{ .iterate = true }) catch @panic("Cannot read diagram helper sources");
    defer directory.close(b.graph.io);
    var walker = directory.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(b.graph.io) catch @panic("Cannot enumerate diagram helper sources")) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.basename, "target")) {
            walker.leave(b.graph.io);
        } else if (entry.kind == .file) {
            paths.append(b.allocator, b.pathJoin(&.{ root, entry.path })) catch @panic("OOM");
        }
    }

    std.mem.sort([]const u8, paths.items, {}, lessThan);
    for (paths.items) |path| {
        run.addFileInput(b.path(path));
    }

    run.addFileInput(b.path("src/assets/IBMPlexSans-Regular.ttf"));
    run.addFileInput(b.path("src/assets/IBMPlexSans-SemiBold.ttf"));
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
