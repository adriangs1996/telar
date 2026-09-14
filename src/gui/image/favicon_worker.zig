//! The favicon job as the GUI runs it on an inbox task: the shared client
//! reads the bounded file, the GUI decodes the PNG and box-filters it into
//! one sprite cell. Allocates freely; it never touches the interactive path.
const std = @import("std");
const client = @import("telar-client");
const png = @import("png.zig");
const box_filter = @import("box_filter.zig");

/// Example: `try inbox.start(.favicon, .{ favicon_worker.execute, .{ io, gpa, job } });`
pub fn execute(io: std.Io, gpa: std.mem.Allocator, job: client.FaviconJob) client.FaviconCompletion {
    return .{ .execution_id = job.execution_id, .workspace = job.workspace, .result = run(io, gpa, job) };
}

fn run(io: std.Io, gpa: std.mem.Allocator, job: client.FaviconJob) !*client.FaviconImage {
    if (job.cell == 0 or job.cell > client.FaviconImage.max_side) {
        return error.InvalidSpriteCell;
    }

    const buffer = try gpa.alloc(u8, client.favicon_lookup.max_file_bytes);
    defer gpa.free(buffer);
    const bytes = try client.favicon_lookup.read(io, job.cwdSlice(), buffer);
    var image = try png.decode(gpa, bytes, .{});
    defer image.deinit(gpa);
    const out = try gpa.create(client.FaviconImage);
    errdefer gpa.destroy(out);
    out.* = .{ .side = job.cell };
    box_filter.resample(image.view(), out.mutableSlice(), job.cell);
    return out;
}
