//! Clipboard platform adapter; no preview store or terminal rendering.

const std = @import("std");
const core = @import("telar-core");
const Io = std.Io;
const schema = core.schema;
const ui = core.ui;
const path_marker = @import("telar-client").attachments.path_marker;
const builtin = @import("builtin");
const types = @import("telar-client").attachments.types;
const max_items = types.max_items;
const max_source_bytes = types.max_source_bytes;
const max_png_bytes = types.max_png_bytes;
const max_pixels = types.max_pixels;
const max_retained_bytes = types.max_retained_bytes;
const max_marker_navigation_steps = types.max_marker_navigation_steps;
const max_removal_keys = types.max_removal_keys;
const deletion_watch_frames = types.deletion_watch_frames;
const Target = types.Target;
const CaptureRequest = types.CaptureRequest;
const MarkerPolicy = types.MarkerPolicy;
const MarkerIdentity = types.MarkerIdentity;
const Capture = types.Capture;
const CaptureResources = types.CaptureResources;
const Id = types.Id;
const Item = types.Item;
const Snapshot = types.Snapshot;
const MarkerScreen = types.MarkerScreen;
const MarkerDeletion = types.MarkerDeletion;
const MarkerRemoval = types.MarkerRemoval;
const DeletionProbe = types.DeletionProbe;
const PendingDeletion = types.PendingDeletion;
const PlanItem = types.PlanItem;
const Plan = types.Plan;

pub fn platformSupported() bool {
    return builtin.os.tag == .macos;
}

pub fn captureClipboard(gpa: std.mem.Allocator, request: CaptureRequest, orphan: *?*Capture) !*Capture {
    try request.target.validate();
    std.debug.assert(orphan.* == null);
    const image = try readClipboardPng(gpa);
    errdefer {
        std.crypto.secureZero(u8, image.png);
        gpa.free(image.png);
    }
    const capture = try gpa.create(Capture);
    capture.* = .{
        .request = request,
        .png = image.png,
        .width = image.width,
        .height = image.height,
    };
    orphan.* = capture;
    return capture;
}

const ClipboardImage = @import("ClipboardImage.zig");

fn readClipboardPng(gpa: std.mem.Allocator) !ClipboardImage {
    if (comptime builtin.os.tag != .macos) {
        return error.ClipboardImageUnsupported;
    }

    var bytes: ?[*]u8 = null;
    var len: usize = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    const result = telar_macos_clipboard_copy_png(
        &bytes,
        &len,
        &width,
        &height,
        max_source_bytes,
        max_png_bytes,
        max_pixels,
    );
    defer if (bytes) |value| {
        if (len <= max_png_bytes) {
            std.crypto.secureZero(u8, value[0..len]);
        }
        std.c.free(@ptrCast(value));
    };
    switch (result) {
        0 => {},
        1 => return error.NoImageOnClipboard,
        2 => return error.ClipboardImageTooLarge,
        else => return error.ClipboardReadFailed,
    }
    const source = bytes orelse return error.ClipboardReadFailed;
    if (len == 0 or len > max_png_bytes or width == 0 or height == 0) {
        return error.InvalidClipboardImage;
    }
    const pixels = std.math.mul(u64, width, height) catch
        return error.ClipboardImageTooLarge;
    if (pixels > max_pixels) {
        return error.ClipboardImageTooLarge;
    }
    const png = try gpa.alloc(u8, len);
    @memcpy(png, source[0..len]);
    return .{ .png = png, .width = width, .height = height };
}

extern fn telar_macos_clipboard_copy_png(bytes: *?[*]u8, len: *usize, width: *u32, height: *u32, max_source_bytes_value: usize, max_png_bytes_value: usize, max_pixels_value: u64) c_int;
