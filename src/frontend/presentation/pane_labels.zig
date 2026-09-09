//! Owned, bounded projection of fullscreen labels for deferred media rendering.

const std = @import("std");
const core = @import("telar-core");
const ui = core.ui;

pub const max_labels = core.schema.max_panes_per_tab;
pub const max_text_bytes = core.schema.max_foreground_name_bytes + 32;

pub const Label = struct {
    offset: u16,
    width: u16,
    selected: bool,
    bytes: [max_text_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn text(label: *const Label) []const u8 {
        return label.bytes[0..label.len];
    }

    fn sameText(a: *const Label, b: *const Label) bool {
        return a.offset == b.offset and a.width == b.width and
            std.mem.eql(u8, a.text(), b.text());
    }
};

pub const PaintedLabel = struct {
    buffer: *const ui.Buffer,
    area: ui.Rect,
    selected: bool,
};

pub const Plan = struct {
    area: ui.Rect = .{},
    labels: [max_labels]Label = undefined,
    len: u8 = 0,

    pub fn slice(plan: *const Plan) []const Label {
        return plan.labels[0..plan.len];
    }

    /// Copies the already truncated cell text, never borrowing pane metadata.
    /// Continuation cells are skipped and grapheme bytes remain intact.
    /// Example: `_ = plan.appendPainted(.{ .buffer = buffer, .area = area, .selected = true });`.
    pub fn appendPainted(plan: *Plan, painted: PaintedLabel) bool {
        if (plan.len == max_labels or painted.area.h != 1 or painted.area.x < plan.area.x or
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
};

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
