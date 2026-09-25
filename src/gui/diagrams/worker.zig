//! Resolves the diagram helper for one owned job on the GUI observation task.
const std = @import("std");
const mermaid = @import("mermaid");
const engine = @import("diagram_renderer_options");
const Job = @import("Job.zig");

const helper_name = "telar-diagram-renderer";

/// The helper ships beside the executable. Builds running from `.zig-cache`
/// fall back to the helper the build produced.
/// Example: `const image = try worker.render(io, allocator, &job);`
pub fn render(io: std.Io, allocator: std.mem.Allocator, job: *const Job) !mermaid.Image {
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const directory = std.fs.path.dirname(executable) orelse return error.RendererUnavailable;
    const installed = try std.fs.path.join(allocator, &.{ directory, helper_name });
    defer allocator.free(installed);

    const helpers = [_][]const u8{ installed, engine.helper_path };
    const development = std.mem.indexOf(u8, executable, "/.zig-cache/") != null;
    return mermaid.render(io, allocator, job.request(), if (development) &helpers else helpers[0..1]);
}
