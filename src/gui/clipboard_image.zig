//! A clipboard image the person pastes into an agent's prompt: the window's
//! own client asks for a capture, a worker reads the pasteboard as a bounded
//! PNG and decodes its preview, and the capture completes in that client,
//! whose shelf adopts the preview. Only macOS reads images; elsewhere the
//! client never asks. One worker runs at a time: a capture requested while
//! another still reads waits for it.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("telar-core");
const data = @import("model");
const client = @import("telar-client");
const GuiAdapter = @import("GuiAdapter.zig");
const window_machines = @import("window_machines.zig");
const PreviewImage = @import("image/PreviewImage.zig");
const preview_decode = @import("image/preview_decode.zig");

/// Whether this platform can read an image from the clipboard.
/// Example: `app.model.host.clipboard_capture = clipboard_image.supported();`
pub fn supported() bool {
    return builtin.os.tag == .macos;
}

/// Starts reading the clipboard for one capture of the window's own client,
/// or queues it behind the worker still running. A request it replaces
/// finishes as cancelled.
///
/// ```zig
/// try clipboard_image.start(gui, request);
/// ```
pub fn start(gui: *GuiAdapter, request: data.CaptureRequest) !void {
    const previews = &gui.previews;
    if (previews.capturing) {
        const replaced = previews.queued;
        previews.queued = request;
        if (replaced) |value| {
            try client.clipboard_capture.completeClipboardCapture(
                window_machines.window(gui),
                .{
                    .execution_id = @enumFromInt(value.sequence),
                    .result = error.Canceled,
                },
            );
        }

        return;
    }

    const app = window_machines.window(gui);
    try gui.driver.inbox.start(.clipboard_image, .{ capture, .{ app.gpa, request, &app.model.clipboard.orphan, &previews.landing } });
    previews.capturing = true;
}

/// Completes the capture in the window's own client, frees a preview it did
/// not adopt and starts the capture waiting behind it, even when that
/// completion failed, so the client never stays busy on a waiting capture.
///
/// ```zig
/// try clipboard_image.finish(gui, completion);
/// ```
pub fn finish(gui: *GuiAdapter, completion: data.Completion) !void {
    const previews = &gui.previews;
    const app = window_machines.window(gui);
    previews.capturing = false;
    const completed = client.clipboard_capture.completeClipboardCapture(app, completion);
    previews.dropLanding();

    if (previews.queued) |queued| {
        previews.queued = null;
        start(gui, queued) catch |err| try client.clipboard_capture.completeClipboardCapture(
            app,
            .{
                .execution_id = @enumFromInt(queued.sequence),
                .result = err,
            },
        );
    }

    return completed;
}

fn capture(gpa: std.mem.Allocator, request: data.CaptureRequest, orphan: *?*data.Capture, landing: *?PreviewImage) data.Completion {
    var limit: ?core.LimitReach = null;
    const result = captureClipboard(gpa, request, orphan, landing, &limit);
    return .{
        .execution_id = @enumFromInt(request.sequence),
        .result = result,
        .limit = limit,
    };
}

fn captureClipboard(gpa: std.mem.Allocator, request: data.CaptureRequest, orphan: *?*data.Capture, landing: *?PreviewImage, limit: *?core.LimitReach) !*data.Capture {
    try request.target.validate();
    std.debug.assert(orphan.* == null);
    std.debug.assert(landing.* == null);
    const image = try readClipboardPng(gpa, limit);
    errdefer {
        std.crypto.secureZero(u8, image.png);
        gpa.free(image.png);
    }

    var preview = try preview_decode.decode(gpa, image.png, request.sequence);
    errdefer preview.deinit(gpa);

    const result = try gpa.create(data.Capture);
    result.* = .{
        .request = request,
        .png = image.png,
        .width = image.width,
        .height = image.height,
    };
    landing.* = preview;
    orphan.* = result;
    return result;
}

// Reads the pasteboard as a bounded PNG; a quota it passes comes back as
// `ClipboardImageTooLarge` with that quota's limit in `limit`.
fn readClipboardPng(gpa: std.mem.Allocator, limit: *?core.LimitReach) !ClipboardImage {
    if (comptime builtin.os.tag != .macos) {
        return error.ClipboardImageUnsupported;
    }

    var bytes: ?[*]u8 = null;
    var len: usize = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    const status = telar_gui_clipboard_copy_png(
        &bytes,
        &len,
        &width,
        &height,
        data.attachment_types.max_source_bytes,
        data.attachment_types.max_png_bytes,
        data.attachment_types.max_pixels,
    );
    defer if (bytes) |value| {
        if (len <= data.attachment_types.max_png_bytes) {
            std.crypto.secureZero(u8, value[0..len]);
        }

        std.c.free(@ptrCast(value));
    };

    switch (@as(ClipboardStatus, @enumFromInt(status))) {
        .ok => {},
        .no_image => return error.NoImageOnClipboard,
        .too_large, .too_many_pixels, .png_too_large => {
            limit.* = quotaReach(@enumFromInt(status), len, width, height);
            return error.ClipboardImageTooLarge;
        },
        _ => return error.ClipboardReadFailed,
    }

    const source = bytes orelse return error.ClipboardReadFailed;
    if (len == 0 or len > data.attachment_types.max_png_bytes or width == 0 or height == 0) {
        return error.InvalidClipboardImage;
    }

    const pixels = std.math.mul(u64, width, height) catch return error.ClipboardImageTooLarge;
    if (pixels > data.attachment_types.max_pixels) {
        limit.* = quotaReach(.too_many_pixels, len, width, height);
        return error.ClipboardImageTooLarge;
    }

    const png = try gpa.alloc(u8, len);
    @memcpy(png, source[0..len]);
    return .{
        .png = png,
        .width = width,
        .height = height,
    };
}

// The limit one quota status of the pasteboard read names, with what the
// image asked for when the read knows it: the PNG's length or its pixels.
fn quotaReach(status: ClipboardStatus, len: usize, width: u32, height: u32) core.LimitReach {
    return switch (status) {
        .png_too_large => .{
            .limit = data.attachment_types.png_bytes_limit,
            .requested = if (len != 0) len else null,
        },
        .too_many_pixels => .{
            .limit = data.attachment_types.pixels_limit,
            .requested = if (width != 0 and height != 0) @as(u64, width) * height else null,
        },
        else => .{
            .limit = data.attachment_types.source_bytes_limit,
        },
    };
}

/// The status codes of `clipboard_image.h`.
const ClipboardStatus = enum(c_int) {
    ok = 0,
    no_image = 1,
    too_large = 2,
    too_many_pixels = 4,
    png_too_large = 5,
    _,
};

const ClipboardImage = struct {
    png: []u8,
    width: u32,
    height: u32,
};

extern fn telar_gui_clipboard_copy_png(bytes: *?[*]u8, len: *usize, width: *u32, height: *u32, max_source_bytes_value: usize, max_png_bytes_value: usize, max_pixels_value: u64) c_int;
