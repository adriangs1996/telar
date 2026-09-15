//! A native progress capsule in pane chrome, never over terminal contents.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Label = @import("Label.zig");
const ProgressRing = @import("ProgressRing.zig");
const ProgressMotions = @import("ProgressMotions.zig");
const Clock = @import("../animation/FrameClock.zig");
const Progress = @This();

pane: *const client.Pane,
area: Rect,
motions: ?*ProgressMotions = null,
/// Tabs retain a ring when there is no room for a percentage beside the name.
compact: bool = false,

/// Width reserved before drawing, using the same label and ring metrics.
/// Example: `const reserved = try progress.width(canvas);`
pub fn width(progress: Progress, canvas: *Canvas) !f32 {
    if (progress.pane.progress_state == .remove) {
        return 0;
    }

    const side = canvas.chrome.px(14);
    const padding = canvas.chrome.px(5);
    if (progress.compact) {
        return side + 2 * padding;
    }

    var storage: [24]u8 = undefined;
    return side + 3 * padding + try canvas.measure(progress.label(canvas, &storage));
}

/// Samples the visible attachment's motion and requests frames only while
/// moving. Error, pause and completed percentages settle without polling.
/// Example: `try progress.draw(canvas);`
pub fn draw(progress: Progress, canvas: *Canvas) !void {
    if (progress.pane.progress_state == .remove or progress.area.width <= 0 or progress.area.height <= 0) {
        return;
    }

    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, progress.area);
    const padding = canvas.chrome.px(5);
    const height = @min(progress.area.height, canvas.chrome.px(20));
    const width_value = @min(progress.area.width, try progress.width(canvas));
    const bounds: Rect = .{ .x = progress.area.x + progress.area.width - width_value, .y = progress.area.y + (progress.area.height - height) / 2, .width = width_value, .height = height };
    const color = progress.progressColor(canvas);
    try canvas.fillRoundedAt(bounds, .{ .radius = height / 2, .color = color });
    canvas.quads.fadeFrom(first, 0.1);
    const side = @max(0, @min(canvas.chrome.px(14), @min(height - canvas.chrome.px(4), bounds.width - 2 * padding)));
    if (side <= 0) {
        return;
    }

    var fraction = @as(f32, @floatFromInt(progress.pane.progress_percent orelse 0)) / 100;
    var rotation: f32 = 0;
    if (canvas.animation) |clock| {
        if (progress.motions) |motions| {
            fraction = motions.fraction(progress.pane, clock);
        }

        if (progress.pane.progress_state == .indeterminate) {
            const period = 1400 * std.time.ns_per_ms;
            const phase = @as(f32, @floatFromInt(clock.now_ns % period)) / period;
            rotation = phase;
            fraction = 0.22 + 0.18 * (1 - @cos(phase * 2 * std.math.pi));
            clock.requestAt(clock.now_ns +| Clock.frame_interval_ns);
        }
    } else if (progress.pane.progress_state == .indeterminate) {
        fraction = 0.35;
    }

    const ring: Rect = .{ .x = bounds.x + padding, .y = bounds.y + (height - side) / 2, .width = side, .height = side };
    try (ProgressRing{ .area = ring, .color = color, .fraction = fraction, .rotation = rotation }).draw(canvas);
    try progress.stateMark(canvas, ring);
    if (!progress.compact) {
        var storage: [24]u8 = undefined;
        const label_x = ring.x + side + padding;
        _ = try canvas.textAt(.{ .x = label_x, .y = bounds.y, .width = @max(0, bounds.x + bounds.width - padding - label_x), .height = height }, progress.label(canvas, &storage));
    }
}

fn stateMark(progress: Progress, canvas: *Canvas, ring: Rect) !void {
    const color = progress.progressColor(canvas);
    const stroke = @max(1, ring.width * 0.1);
    const center = ring.x + ring.width / 2;
    const top = ring.y + ring.height * 0.32;
    if (progress.pane.progress_state == .pause) {
        for ([_]f32{ -1.5, 0.5 }) |offset| {
            try canvas.fillRoundedAt(.{ .x = center + offset * stroke, .y = top, .width = stroke, .height = ring.height * 0.36 }, .{ .radius = stroke / 2, .color = color });
        }
    } else if (progress.pane.progress_state == .@"error") {
        try canvas.fillRoundedAt(.{ .x = center - stroke / 2, .y = top, .width = stroke, .height = ring.height * 0.24 }, .{ .radius = stroke / 2, .color = color });
        try canvas.fillRoundedAt(.{ .x = center - stroke / 2, .y = ring.y + ring.height * 0.63, .width = stroke, .height = stroke }, .{ .radius = stroke / 2, .color = color });
    }
}

fn label(progress: Progress, canvas: *Canvas, storage: []u8) Label {
    const text: []const u8 = switch (progress.pane.progress_state) {
        .indeterminate => "Working",
        .pause => "Paused",
        .@"error" => "Error",
        .set => std.fmt.bufPrint(storage, "{d}%", .{progress.pane.progress_percent orelse 0}) catch unreachable,
        .remove => "",
    };
    return .{ .text = text, .color = progress.progressColor(canvas), .face = .sans, .size = .small };
}

fn progressColor(progress: Progress, canvas: *const Canvas) core.Color {
    return switch (progress.pane.progress_state) {
        .@"error" => canvas.theme.palette.red,
        .pause => canvas.theme.palette.yellow,
        else => canvas.theme.palette.teal,
    };
}
