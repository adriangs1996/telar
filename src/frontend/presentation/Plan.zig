const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Label = @import("Label.zig");
const std = @import("std");
const Plan = @This();

area: cellgrid.Rect = .{},
labels: [core.max_panes_per_tab]Label = undefined,
len: u8 = 0,

pub fn slice(self: *const Plan) []const Label {
    return self.labels[0..self.len];
}

/// Copies the already truncated cell text, never borrowing pane metadata.
/// Continuation cells are skipped and grapheme bytes remain intact.
/// Example: `_ = plan.appendPainted(.{ .buffer = buffer, .area = area, .selected = true });`.
pub fn appendPainted(self: *Plan, painted: PaintedLabel) bool {
    if (self.len == core.max_panes_per_tab or painted.area.h != 1 or painted.area.x < self.area.x or
        !std.meta.eql(painted.area, painted.area.intersect(painted.buffer.area())))
    {
        return false;
    }

    var label: Label = .{
        .offset = painted.area.x - self.area.x,
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
    self.labels[self.len] = label;
    self.len += 1;
    return true;
}

/// Ignores focus and strip position while comparing text and label geometry.
/// Example: `const stable = plan.sameText(previous);`.
pub fn sameText(self: *const Plan, other: *const Plan) bool {
    if (self.area.w != other.area.w or self.area.h != other.area.h or self.len != other.len) {
        return false;
    }

    for (self.slice(), other.slice()) |*left, *right| {
        if (!left.sameText(right)) {
            return false;
        }
    }

    return true;
}

/// Compares only initialized labels; movement does not change image content.
/// Example: `const reusable = plan.sameContent(previous);`.
pub fn sameContent(self: *const Plan, other: *const Plan) bool {
    if (!self.sameText(other)) {
        return false;
    }

    for (self.slice(), other.slice()) |left, right| {
        if (left.selected != right.selected) {
            return false;
        }
    }

    return true;
}

const PaintedLabel = struct {
    buffer: *const cellgrid.Buffer,
    area: cellgrid.Rect,
    selected: bool,
};
