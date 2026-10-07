const std = @import("std");
const Application = @import("Application.zig");
const macos_gui = @import("macos_gui.zig");
const linux_gui = @import("linux_gui.zig");
const Modules = @import("Modules.zig");

/// Attach the native adapter: `gui.add(b, app, diagram_helper)`.
pub fn add(b: *std.Build, app: Application, diagram_helper: ?std.Build.LazyPath) ?*std.Build.Module {
    // GPU chrome over the shared client. Mermaid rasterization runs in an
    // isolated Rust helper.
    var gui_module: ?*std.Build.Module = null;
    if (app.modules.native_client) {
        const gui = zigModule(b, app.modules, diagram_helper.?);
        if (app.modules.target.result.os.tag == .macos) {
            macos_gui.add(b, gui);
        } else {
            linux_gui.add(b, gui);
        }
        const probe = b.createModule(.{
            .root_source_file = b.path("src/gui/profiling_main.zig"),
            .target = app.modules.target,
            .optimize = app.modules.optimize,
            .link_libc = true,
        });
        var imports = gui.import_table.iterator();
        while (imports.next()) |entry| {
            probe.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
        probe.addOptions("profile_options", app.modules.build_options);
        if (app.modules.target.result.os.tag == .macos) {
            macos_gui.add(b, probe);
        } else {
            linux_gui.add(b, probe);
        }
        const executable = b.addExecutable(.{ .name = "telar-dod-probe", .root_module = probe });
        b.step("build-dod-probe", "Build CPU-only native workloads and storage report").dependOn(&b.addInstallArtifact(executable, .{}).step);
        app.exe.root_module.addImport("telar-gui", gui);
        const run_gui = b.addRunArtifact(app.exe);
        run_gui.addArg("gui");
        if (b.args) |args| {
            run_gui.addArgs(args);
        }
        b.step("gui", "Run the native client through `telar gui`").dependOn(&run_gui.step);
        gui_module = gui;
    }

    return gui_module;
}

/// The native adapter's Zig code with its imports and the portable wake pipe,
/// before the platform's window sources link in.
///
/// ```zig
/// const gui = gui_build.zigModule(b, modules, diagram_helper);
/// ```
pub fn zigModule(b: *std.Build, modules: Modules, diagram_helper: std.Build.LazyPath) *std.Build.Module {
    const gui = b.createModule(.{
        .root_source_file = b.path("src/gui/gui.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
        .link_libc = true,
    });
    gui.addIncludePath(b.path("src/gui/native"));
    gui.addImport("freetype", modules.freetype);
    gui.addImport("assets", modules.assets);
    gui.addImport("telar-client", modules.client);
    gui.addImport("model", modules.data);
    gui.addImport("telar-core", modules.core);
    modules.libraries.addImports(gui);
    const diagram_options = b.addOptions();
    diagram_options.addOptionPath("helper_path", diagram_helper);
    gui.addOptions("diagram_renderer_options", diagram_options);
    return gui;
}
