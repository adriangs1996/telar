//! Retained heights of conversation messages. Measuring a message shapes
//! every word, including rows far outside the viewport, and a transcript is
//! re-resolved on every frame it is visible. A message whose layout inputs
//! are unchanged reuses its height; any change is a different key.
const std = @import("std");
const Entry = @import("MessageHeightEntry.zig");
const Key = @import("MessageHeightKey.zig");
const Heights = @This();

/// Direct mapped; a conflict only costs a re-measurement.
pub const capacity = 4096;

entries: [capacity]?Entry = @splat(null),

/// Example: `if (heights.find(key)) |height| return height;`
pub fn find(heights: *const Heights, key: Key) ?f32 {
    const entry = heights.entries[slot(key)] orelse return null;
    if (!std.meta.eql(entry.key, key)) {
        return null;
    }

    return entry.height;
}

/// Example: `heights.remember(key, height);`
pub fn remember(heights: *Heights, key: Key, height: f32) void {
    heights.entries[slot(key)] = .{
        .key = key,
        .height = height,
    };
}

fn slot(key: Key) usize {
    return @intCast((key.text_hash ^ @as(u32, @bitCast(key.width))) % capacity);
}

test "message heights hit only for identical layout inputs" {
    const heights = try std.testing.allocator.create(Heights);
    defer std.testing.allocator.destroy(heights);
    heights.* = .{};
    const key: Key = .{ .text_hash = 7, .text_len = 3, .width = 400, .font_identity = 1, .font_revision = 0, .chrome = .{}, .metrics = .{ .cell_width = 9, .cell_height = 22, .baseline = 17, .pixel_height = 15 }, .role = .assistant, .complete = true, .identified = true, .fragment_start = true, .fragment_end = true };
    try std.testing.expectEqual(@as(?f32, null), heights.find(key));
    heights.remember(key, 120);
    try std.testing.expectEqual(@as(?f32, 120), heights.find(key));
    var wider = key;
    wider.width = 401;
    try std.testing.expectEqual(@as(?f32, null), heights.find(wider));
    var reloaded = key;
    reloaded.font_revision = 1;
    try std.testing.expectEqual(@as(?f32, null), heights.find(reloaded));
    var streaming = key;
    streaming.complete = false;
    try std.testing.expectEqual(@as(?f32, null), heights.find(streaming));
}
