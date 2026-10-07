//! A clipboard image the person pastes into an agent's prompt: the window's
//! own client asks for a capture, the window supplies a native source, and a
//! worker reads a bounded PNG and decodes its preview. The capture completes
//! in that client, whose shelf adopts the preview. One worker runs at a time;
//! a capture requested while another still reads waits for it.

const std = @import("std");
const Window = @import("telar-window");
const imaging = @import("imaging");
const core = @import("telar-core");
const data = @import("model");
const PreviewImage = @import("image/PreviewImage.zig");
const preview_decode = @import("image/preview_decode.zig");

pub fn capture(gpa: std.mem.Allocator, request: data.CaptureRequest, source_value: Window.ClipboardSource, orphan: *?*data.Capture, landing: *?PreviewImage) data.Completion {
    var source = source_value;
    defer source.deinit();
    var limit: ?core.LimitReach = null;
    const png = source.read(gpa, .{ .source_bytes = data.attachment_types.max_source_bytes, .png_bytes = data.attachment_types.max_png_bytes, .pixels = data.attachment_types.max_pixels });
    const result = captureClipboard(gpa, request, png, orphan, landing);
    if (result) |_| {} else |err| {
        limit = quotaReach(err);
    }
    return .{
        .execution_id = @enumFromInt(request.sequence),
        .result = if (limit != null) error.ClipboardImageTooLarge else result,
        .limit = limit,
    };
}

fn captureClipboard(gpa: std.mem.Allocator, request: data.CaptureRequest, png_result: anyerror![]u8, orphan: *?*data.Capture, landing: *?PreviewImage) !*data.Capture {
    std.debug.assert(orphan.* == null);
    std.debug.assert(landing.* == null);
    const png = try png_result;
    errdefer {
        std.crypto.secureZero(u8, png);
        gpa.free(png);
    }

    try request.target.validate();
    const width, const height = try imaging.png.dimensions(png);
    if (width == 0 or height == 0) {
        return error.InvalidClipboardImage;
    }
    if (@as(u64, width) * height > data.attachment_types.max_pixels) {
        return error.ClipboardPixelsTooLarge;
    }
    var preview = try preview_decode.decode(gpa, png, request.sequence);
    errdefer preview.deinit(gpa);

    const result = try gpa.create(data.Capture);
    result.* = .{
        .request = request,
        .png = png,
        .width = width,
        .height = height,
    };
    landing.* = preview;
    orphan.* = result;
    return result;
}

// Libraries report quota errors; only this client completion reports named limits.
fn quotaReach(err: anyerror) ?core.LimitReach {
    return switch (err) {
        error.ClipboardSourceTooLarge => .{ .limit = data.attachment_types.source_bytes_limit },
        error.ClipboardPngTooLarge => .{ .limit = data.attachment_types.png_bytes_limit },
        error.ClipboardPixelsTooLarge => .{ .limit = data.attachment_types.pixels_limit },
        else => null,
    };
}
