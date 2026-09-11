const RectType = @import("telar-core").Rect;
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const Label = @import("Label.zig");
const PaintedLabel = @import("PaintedLabel.zig");
const std = @import("std");
const Plan = @This();

area: RectType = .{},
labels: [max_panes_per_tab]Label = undefined,
len: u8 = 0,

pub fn slice(plan: *const Plan) []const Label {
    return plan.labels[0..plan.len];
}

/// Copies the already truncated cell text, never borrowing pane metadata.
/// Continuation cells are skipped and grapheme bytes remain intact.
/// Example: `_ = plan.appendPainted(.{ .buffer = buffer, .area = area, .selected = true });`.
pub fn appendPainted(plan: *Plan, painted: PaintedLabel) bool {
    if (plan.len == max_panes_per_tab or painted.area.h != 1 or painted.area.x < plan.area.x or
        !std.meta.eql(painted.area, painted.area.intersect(painted.buffer.area())))
    {
        return false;
    }

    var label: Label = .{
        .offset = painted.area.x - plan.area.x,
        .width = painted.area.w,
        .selected = painted.selected,
    };
    for (0..painted.area.w) |offset| {
        const cell = &painted.buffer.cells[@as(usize, painted.area.y) * painted.buffer.w + painted.area.x + offset];
        if (cell.width == 0) {
            continue;
        }

        const text = cell.text();
        if (text.len > label.bytes.len - label.len) {
            return false;
        }

        @memcpy(label.bytes[label.len..][0..text.len], text);
        label.len += @intCast(text.len);
    }

    const trimmed = std.mem.trim(u8, label.text(), " ");
    std.mem.copyForwards(u8, &label.bytes, trimmed);
    label.len = @intCast(trimmed.len);
    plan.labels[plan.len] = label;
    plan.len += 1;
    return true;
}

/// Ignores focus and strip position while comparing text and label geometry.
/// Example: `const stable = plan.sameText(previous);`.
pub fn sameText(plan: *const Plan, other: *const Plan) bool {
    if (plan.area.w != other.area.w or plan.area.h != other.area.h or plan.len != other.len) {
        return false;
    }

    for (plan.slice(), other.slice()) |*left, *right| {
        if (!left.sameText(right)) {
            return false;
        }
    }

    return true;
}

/// Compares only initialized labels; movement does not change image content.
/// Example: `const reusable = plan.sameContent(previous);`.
pub fn sameContent(plan: *const Plan, other: *const Plan) bool {
    if (!plan.sameText(other)) {
        return false;
    }

    for (plan.slice(), other.slice()) |left, right| {
        if (left.selected != right.selected) {
            return false;
        }
    }

    return true;
}
