const std = @import("std");
const Libraries = @import("Libraries.zig");

/// The libraries the model may import: pure values and deadlines, no I/O.
pub const libraries = [_][]const u8{ "cellgrid", "pacing" };

/// Builds shared values for the same target and optimization as their core dependency.
/// Example: `const data = model_build.create(b, core, app_libraries);`
pub fn create(b: *std.Build, core: *std.Build.Module, available: Libraries) *std.Build.Module {
    const data = b.createModule(
        .{
            .root_source_file = b.path("src/model/model.zig"),
            .target = core.resolved_target,
            .optimize = core.optimize,
        },
    );
    data.addImport("telar-core", core);
    available.addSelectedImports(data, &libraries);
    return data;
}
