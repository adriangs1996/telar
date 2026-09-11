//! Owned, bounded projection of fullscreen labels for deferred media rendering.

const std = @import("std");
const core = @import("telar-core");
pub const ui = core.ui;

pub const max_labels = core.schema.max_panes_per_tab;
pub const max_text_bytes = core.schema.max_foreground_name_bytes + 32;

pub const Label = @import("Label.zig");

pub const PaintedLabel = @import("PaintedLabel.zig");

pub const Plan = @import("Plan.zig");

test "label plans own cell text and compare content independently of position" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 20, 1);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = " 1 e\u{301}界 " });
    var plan: Plan = .{ .area = .{ .w = 8, .h = 1 } };
    try std.testing.expect(plan.appendPainted(.{ .buffer = &buffer, .area = plan.area, .selected = true }));
    try std.testing.expectEqualStrings("1 e\u{301}界", plan.labels[0].text());
    buffer.clear(.{});
    try std.testing.expectEqualStrings("1 e\u{301}界", plan.labels[0].text());
    var moved = plan;
    moved.area.x = 10;
    try std.testing.expect(plan.sameContent(&moved));
    moved.labels[0].selected = false;
    try std.testing.expect(!plan.sameContent(&moved));
    try std.testing.expect(plan.sameText(&moved));
    moved.labels[0].width += 1;
    try std.testing.expect(!plan.sameText(&moved));
    moved = plan;
    moved.labels[0].bytes[0] = '2';
    try std.testing.expect(!plan.sameText(&moved));
}
