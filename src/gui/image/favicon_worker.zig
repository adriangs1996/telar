//! The favicon job as the GUI runs it on an inbox task: the shared client
//! reads the bounded file, the GUI decodes it and resizes it into one cell
//! per sprite size, averaging to shrink and blending to grow. A PNG decodes
//! once; an ICO decodes the frame closest above each cell. Allocates
//! freely; it never touches the interactive path.
const std = @import("std");
const client = @import("telar-client");
const imaging = @import("imaging");
const png = imaging.png;
const ico = imaging.ico;
const resize = imaging.resize;
const SpritePage = @import("SpritePage.zig");
const SpriteSize = @import("SpriteSize.zig").SpriteSize;

comptime {
    std.debug.assert(SpritePage.max_cell <= client.FaviconImage.max_side);
    std.debug.assert(SpriteSize.count == client.FaviconImage.max_cells);
}

/// Example: `try inbox.start(.favicon, .{ favicon_worker.execute, .{ io, gpa, job } });`
pub fn execute(io: std.Io, gpa: std.mem.Allocator, job: client.FaviconJob) client.FaviconCompletion {
    return .{ .execution_id = job.execution_id, .workspace = job.workspace, .result = run(io, gpa, job) };
}

fn run(io: std.Io, gpa: std.mem.Allocator, job: client.FaviconJob) !*client.FaviconImage {
    for (job.cells) |cell| {
        if (cell == 0 or cell > client.FaviconImage.max_side) {
            return error.InvalidSpriteCell;
        }
    }

    const buffer = try gpa.alloc(u8, client.favicon_lookup.max_file_bytes);
    defer gpa.free(buffer);
    const bytes = try client.favicon_lookup.read(io, job.cwdSlice(), buffer);
    const out = try gpa.create(client.FaviconImage);
    errdefer gpa.destroy(out);
    out.* = .{ .sides = job.cells };

    if (std.mem.startsWith(u8, bytes, "\x00\x00\x01\x00")) {
        for (job.cells, 0..) |cell, index| {
            var frame = try ico.decode(gpa, bytes, cell);
            defer frame.deinit(gpa);
            resize.square(frame.view(), out.mutableSlice(index), cell);
        }

        return out;
    }

    var image = try png.decode(gpa, bytes, .{});
    defer image.deinit(gpa);
    for (job.cells, 0..) |cell, index| {
        resize.square(image.view(), out.mutableSlice(index), cell);
    }

    return out;
}
