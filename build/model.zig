const std = @import("std");

/// Builds shared values for the same target and optimization as their core dependency.
/// Example: `const data = model_build.create(b, core);`
pub fn create(b: *std.Build, core: *std.Build.Module) *std.Build.Module {
    const data = b.createModule(
        .{
            .root_source_file = b.path("src/model/model.zig"),
            .target = core.resolved_target,
            .optimize = core.optimize,
        },
    );
    data.addImport("telar-core", core);
    return data;
}
