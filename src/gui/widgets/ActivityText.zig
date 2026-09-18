//! Visible activity text uses the scene's single clock. Idle text never
//! schedules work, and animation only changes cached glyph opacity.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Label = @import("Label.zig");
const FrameClock = @import("../animation/FrameClock.zig");
const ActivityText = @This();

bounds: Rect,
label: Label,
active: bool = false,

/// Call only for visible rows. Example: `try (ActivityText{ .bounds = row, .label = label, .active = working }).draw(canvas);`
pub fn draw(activity: ActivityText, canvas: *Canvas) !void {
    if (activity.bounds.width <= 0 or activity.bounds.height <= 0 or activity.label.text.len == 0) {
        return;
    }

    const first = canvas.quads.items().len;
    const width = try canvas.textAt(activity.bounds, activity.label);
    if (!activity.active or first == canvas.quads.items().len) {
        return;
    }

    const clock = canvas.animation orelse return;
    const steps = 108;
    const step = clock.step(FrameClock.frame_interval_ns) % steps;
    const radius = @max(canvas.chrome.px(20), width * 0.35);
    const progress = @as(f32, @floatFromInt(step)) / steps;
    canvas.quads.highlightFrom(first, .{ .center = activity.bounds.x - radius + (width + 2 * radius) * progress, .radius = radius });
}

test "activity animates cached glyphs and parks when complete or invisible" {
    var atlas = try @import("../text/GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var quads = @import("../render/QuadList.zig").init(std.testing.allocator);
    defer quads.deinit();
    var clock: FrameClock = .{};
    var canvas: Canvas = .{ .atlas = &atlas, .quads = &quads, .origin = .{ 0, 0 }, .metrics = .{ .cell_width = 10, .cell_height = 24, .baseline = 18, .pixel_height = 16 }, .theme = @import("telar-client").theme_support.default_theme, .animation = &clock, .chrome = .{ .body = 16, .title = 18, .small = 12 } };
    var activity: ActivityText = .{ .bounds = .{ .x = 0, .y = 0, .width = 240, .height = 32 }, .label = .{ .text = "Thinking", .face = .sans, .size = .body }, .active = true };
    clock.begin(0);
    try activity.draw(&canvas);
    try std.testing.expect(clock.deadline_ns != null);
    const shapes = atlas.shape_calls;
    const version = atlas.version;
    const first_alpha = quads.items()[0].a;
    quads.clear();
    clock.begin(40 * FrameClock.frame_interval_ns);
    try activity.draw(&canvas);
    try std.testing.expectEqual(shapes, atlas.shape_calls);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expect(quads.items()[0].a > first_alpha);
    activity.active = false;
    quads.clear();
    clock.begin(clock.now_ns + 1);
    try activity.draw(&canvas);
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    activity.active = true;
    activity.bounds.width = 0;
    quads.clear();
    clock.begin(clock.now_ns + 1);
    try activity.draw(&canvas);
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    try std.testing.expectEqual(@as(usize, 0), quads.items().len);
}
