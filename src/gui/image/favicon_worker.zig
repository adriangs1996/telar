//! The favicon job as the GUI runs it on an inbox task: the shared client
//! reads the bounded file, the GUI decodes it and resizes it into one cell
//! per sprite size, averaging to shrink and blending to grow. A PNG decodes
//! once; an ICO decodes the frame closest above each cell. Allocates
//! freely; it never touches the interactive path. A PNG past
//! `max_png_side` returns its reach in the completion, which the window
//! reports when the lookup lands.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const imaging = @import("imaging");
const png = imaging.png;
const ico = imaging.ico;
const resize = imaging.resize;
const SpritePage = @import("SpritePage.zig");
const SpriteSize = @import("SpriteSize.zig").SpriteSize;

/// The widest or tallest favicon PNG decoded. Logos ship at 2048 or 4096
/// pixels a side and are resized to a cell of at most `SpritePage.max_cell`
/// texels. The file is at most `favicon_lookup.max_file_bytes` (1 MiB), yet
/// a flat image that size can declare the whole square, so one decode holds
/// the 64 MiB of RGBA plus Wuffs's work buffer of one filter byte a row and
/// one to eight bytes a pixel: 128 MiB for 8-bit RGBA and 192 MiB at worst
/// (16-bit RGBA), on this worker for the length of the decode.
pub const max_png_side: u32 = 4096;
/// Every PNG past `max_png_pixels` also has a side past `max_png_side`, so
/// the side names the limit.
pub const max_png_pixels: u32 = max_png_side * max_png_side;
pub const png_side_limit = core.Limit.declare("gui.favicons.max_png_side", "pixels per side", max_png_side);

comptime {
    std.debug.assert(SpritePage.max_cell <= client.FaviconImage.max_side);
    std.debug.assert(SpriteSize.count == client.FaviconImage.max_cells);
}

/// Looks one workspace's favicon up; a PNG past `max_png_side` comes back
/// as `error.PngTooLarge` with the reach of `png_side_limit`.
/// Example: `try inbox.start(.favicon, .{ favicon_worker.execute, .{ io, gpa, job } });`
pub fn execute(io: std.Io, gpa: std.mem.Allocator, job: client.FaviconJob) client.FaviconCompletion {
    var limit: ?core.LimitReach = null;
    const result = run(io, gpa, job, &limit);
    return .{
        .execution_id = job.execution_id,
        .workspace = job.workspace,
        .result = result,
        .limit = limit,
    };
}

fn run(io: std.Io, gpa: std.mem.Allocator, job: client.FaviconJob, limit: *?core.LimitReach) !*client.FaviconImage {
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

    var image = png.decode(
        gpa,
        bytes,
        .{
            .max_side = max_png_side,
            .max_pixels = max_png_pixels,
        },
    ) catch |err| {
        if (err == error.PngTooLarge) {
            limit.* = pngReach(bytes);
        }

        return err;
    };
    defer image.deinit(gpa);
    for (job.cells, 0..) |cell, index| {
        resize.square(image.view(), out.mutableSlice(index), cell);
    }

    return out;
}

// The reach of a PNG `decode` refused: the longer side its header declares.
fn pngReach(bytes: []const u8) core.LimitReach {
    const width, const height = png.dimensions(bytes) catch return .{
        .limit = png_side_limit,
    };
    return .{
        .limit = png_side_limit,
        .requested = @max(width, height),
    };
}
