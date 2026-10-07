const std = @import("std");

/// Font discovery used by GUI frame preparation; telar-window owns Wayland.
pub fn add(b: *std.Build, gui: *std.Build.Module) void {
    gui.addCSourceFile(.{ .file = b.path("src/gui/linux/font.c"), .flags = &.{"-std=c11"} });
    gui.linkSystemLibrary("fontconfig", .{});
}

pub fn addProtocol(b: *std.Build, module: *std.Build.Module, name: []const u8) void {
    addProtocolHeader(b, module, name);
    const path = b.fmt("/usr/share/wayland-protocols/{s}.xml", .{name});
    const stem = std.fs.path.basename(name);
    const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    code.addFileArg(.{ .cwd_relative = path });
    const code_file = code.addOutputFileArg(b.fmt("{s}-protocol.c", .{stem}));
    module.addCSourceFile(.{ .file = code_file, .flags = &.{"-std=c11"} });
}

fn addProtocolHeader(b: *std.Build, module: *std.Build.Module, name: []const u8) void {
    const path = b.fmt("/usr/share/wayland-protocols/{s}.xml", .{name});
    const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    header.addFileArg(.{ .cwd_relative = path });
    const file = header.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{std.fs.path.basename(name)}));
    module.addIncludePath(file.dirname());
}
