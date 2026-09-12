const std = @import("std");
const c_flags = @import("c_flags.zig");

/// Wayland through xdg-shell and Vulkan through the system loader. The
/// xdg-shell client code is generated from the protocol the distribution
/// installs, so the machine building Telar needs `wayland-scanner`,
/// `wayland-protocols` and the Vulkan headers.
pub fn add(b: *std.Build, gui: *std.Build.Module, disable_coverage: bool) void {
    const protocol = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
    const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", protocol });
    const header_file = header.addOutputFileArg("xdg-shell-client-protocol.h");
    const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", protocol });
    const code_file = code.addOutputFileArg("xdg-shell-protocol.c");
    const flags = c_flags.forCoverage(b, &.{"-std=c11"}, disable_coverage);
    gui.addIncludePath(header_file.dirname());
    gui.addCSourceFile(.{ .file = code_file, .flags = flags });
    gui.addCSourceFile(.{ .file = b.path("src/gui/linux/window.c"), .flags = flags });
    gui.addCSourceFile(.{ .file = b.path("src/gui/linux/input.c"), .flags = flags });
    gui.addCSourceFile(.{ .file = b.path("src/gui/linux/frame_worker.c"), .flags = flags });
    gui.linkSystemLibrary("xkbcommon", .{});
    gui.addCSourceFile(.{ .file = b.path("src/gui/linux/renderer.c"), .flags = flags });
    gui.addCSourceFile(.{ .file = spirvSource(b, "quad.vert", "telar_gui_quad_vert_spv"), .flags = flags });
    gui.addCSourceFile(.{ .file = spirvSource(b, "quad.frag", "telar_gui_quad_frag_spv"), .flags = flags });
    gui.linkSystemLibrary("wayland-client", .{});
    gui.linkSystemLibrary("vulkan", .{});
}

/// Embeds a compiled shader as a C array so every binary that links the
/// Linux backend carries it. Regenerate the `.spv` with `glslc` after editing
/// the GLSL next to it.
fn spirvSource(b: *std.Build, shader: []const u8, symbol: []const u8) std.Build.LazyPath {
    const spv_path = b.fmt("src/gui/shaders/{s}.spv", .{shader});
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.pathFromRoot(spv_path), b.allocator, .limited(1 << 20)) catch |err| {
        std.debug.panic("cannot read {s}: {s}", .{ spv_path, @errorName(err) });
    };
    std.debug.assert(bytes.len % 4 == 0);
    var source: std.Io.Writer.Allocating = .init(b.allocator);
    const writer = &source.writer;
    writer.print("#include <stdint.h>\nconst uint32_t {s}_bytes = {d};\nconst uint32_t {s}[] = {{", .{ symbol, bytes.len, symbol }) catch @panic("OOM");
    var index: usize = 0;
    while (index < bytes.len) : (index += 4) {
        writer.print("{s}0x{x:0>8}", .{ if (index == 0) "" else ",", std.mem.readInt(u32, bytes[index..][0..4], .little) }) catch @panic("OOM");
    }
    writer.writeAll("};\n") catch @panic("OOM");
    return b.addWriteFiles().add(b.fmt("{s}.c", .{symbol}), source.written());
}
