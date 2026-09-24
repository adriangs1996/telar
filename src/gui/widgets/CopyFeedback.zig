//! One transient clipboard confirmation; repeated copies replace its deadline.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Label = @import("Label.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Result = @import("../input/ClipboardResult.zig");
const CopyFeedback = @This();

const duration_ns = 2 * std.time.ns_per_s;
const horizontal_padding = 12;
const vertical_padding = 7;
const bottom_margin = 12;
const corner_radius = 7;

pending: ?u64 = null,
until_ns: u64 = 0,

/// Only the latest admitted request may confirm a copy.
/// Example: `if (feedback.complete(result, now_ns)) requestFrame();`
pub fn complete(self: *CopyFeedback, result: Result, now_ns: u64) bool {
    if (self.pending != result.request_id) {
        return false;
    }

    self.pending = null;
    if (result.status != .success) {
        return false;
    }

    self.until_ns = now_ns +| duration_ns;
    return true;
}

/// Paints a passive bottom label and schedules only its expiration.
/// Example: `try feedback.draw(canvas);`
pub fn draw(self: *const CopyFeedback, canvas: *Canvas) !void {
    const clock = canvas.animation orelse return;
    if (clock.now_ns >= self.until_ns) {
        return;
    }

    const label: Label = .{ .text = "Copy to clipboard", .face = .sans, .size = .small, .color = canvas.theme.palette.text };
    const padding_x = canvas.chrome.px(horizontal_padding);
    const padding_y = canvas.chrome.px(vertical_padding);
    const margin = canvas.chrome.px(bottom_margin);
    const width = try canvas.measure(label) + 2 * padding_x;
    const height = canvas.chrome.rowHeight(.small) + 2 * padding_y;
    const window_width: f32 = @floatFromInt(canvas.viewport[0]);
    const bottom = @as(f32, @floatFromInt(canvas.viewport[1] -| canvas.chrome.status_bar));
    if (width + 2 * margin > window_width or height + 2 * margin > bottom) {
        return;
    }

    clock.requestAt(self.until_ns);
    const area: Rect = .{ .x = (window_width - width) / 2, .y = bottom - margin - height, .width = width, .height = height };
    try canvas.fillRoundedAt(area, .{ .color = canvas.theme.palette.surface0, .radius = canvas.chrome.px(corner_radius) });
    try canvas.ringAt(area, .{ .color = canvas.theme.palette.overlay0, .width = 1, .radius = canvas.chrome.px(corner_radius), .alpha = 0.7 });
    _ = try canvas.textAt(.{ .x = area.x + padding_x, .y = area.y + padding_y, .width = width - 2 * padding_x, .height = height - 2 * padding_y }, label);
}

test "copy confirmation rejects failures obsolete requests and duplicate completions" {
    var feedback: CopyFeedback = .{ .pending = 2 };
    var result: Result = .{ .request_id = 1, .target_id = 0, .generation = 0, .status = .success };
    try std.testing.expect(!feedback.complete(result, 10));
    try std.testing.expectEqual(@as(u64, 0), feedback.until_ns);
    result.request_id = 2;
    result.status = .cancelled;
    try std.testing.expect(!feedback.complete(result, 20));
    try std.testing.expect(feedback.pending == null);
    feedback.pending = 3;
    result.request_id = 3;
    result.status = .success;
    try std.testing.expect(feedback.complete(result, 30));
    try std.testing.expectEqual(30 + duration_ns, feedback.until_ns);
    try std.testing.expect(!feedback.complete(result, 40));
    try std.testing.expectEqual(30 + duration_ns, feedback.until_ns);
}
