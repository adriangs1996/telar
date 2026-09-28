const std = @import("std");
const Modules = @import("Modules.zig");

/// Builds pinned, vendored grammars into the native adapters. No network at build.
/// Example: `const archive = syntax_highlighter.add(b, app.modules);`
pub fn add(b: *std.Build, modules: Modules) ?std.Build.LazyPath {
    const target = modules.target.result;
    if (!modules.native_client) {
        return null;
    }

    const architecture = switch (target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @panic("Syntax highlighting supports aarch64 and x86_64 native targets"),
    };
    const platform = if (target.os.tag == .macos) "apple-darwin" else if (target.abi == .musl) "unknown-linux-musl" else "unknown-linux-gnu";
    const triple = b.fmt("{s}-{s}", .{ architecture, platform });
    const compile = b.addSystemCommand(&.{ "cargo", "build", "--quiet", "--locked", "--offline", "--release", "--target", triple, "--target-dir" });
    const output = compile.addOutputDirectoryArg("syntax-highlighter");
    inputs(b, compile);
    const tests = b.addSystemCommand(&.{ "cargo", "test", "--quiet", "--locked", "--offline", "--release", "--target-dir" });
    _ = tests.addOutputDirectoryArg("syntax-tests");
    inputs(b, tests);
    b.step("test-syntax-highlighter", "Test vendored grammars, captures and FFI limits").dependOn(&tests.step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("tools/syntax-highlighter/licenses"),
        .install_dir = .prefix,
        .install_subdir = "share/telar/syntax-highlighter/licenses",
    }).step);
    return output.path(b, b.fmt("{s}/release/libtelar_syntax_highlighter.a", .{triple}));
}

fn inputs(b: *std.Build, run: *std.Build.Step.Run) void {
    const root = "tools/syntax-highlighter";
    run.setCwd(b.path(root));
    var directory = b.build_root.handle.openDir(b.graph.io, root, .{ .iterate = true }) catch @panic("Cannot read syntax library");
    defer directory.close(b.graph.io);
    var walker = directory.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(b.graph.io) catch @panic("Cannot enumerate syntax library")) |entry| {
        if (entry.kind == .file) {
            paths.append(b.allocator, b.pathJoin(&.{ root, entry.path })) catch @panic("OOM");
        }
    }

    std.mem.sort([]const u8, paths.items, {}, lessThan);
    for (paths.items) |path| {
        run.addFileInput(b.path(path));
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
