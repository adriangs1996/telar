const PanelHeading = @import("PanelHeading.zig");
const model = @import("model.zig");
const std = @import("std");
const Layout = @This();

generation: u64 = 0,
live_mask: u8 = 0,
bottom: [3]model.Slot = .{ .{ .content = model.metrics_content }, .empty, .tabs },
top_right: model.Slot = .empty,
sidebar_footer: [3]model.Slot = .{ .{ .content = model.metrics_content }, .empty, .empty },
/// How each configured panel is drawn, by the index actions refer to.
panels: [model.max_panels]PanelHeading = @splat(.{}),
panel_count: u8 = 0,

pub fn slot(self: *const Layout, position: model.Position) *const model.Slot {
    return switch (position) {
        .bottom_left => &self.bottom[0],
        .bottom_center => &self.bottom[1],
        .bottom_right => &self.bottom[2],
        .top_right => &self.top_right,
        .sidebar_footer_left => &self.sidebar_footer[0],
        .sidebar_footer_center => &self.sidebar_footer[1],
        .sidebar_footer_right => &self.sidebar_footer[2],
    };
}

/// The components shown at a position, when it holds any.
/// Example: `const content = layout.content(.bottom_left) orelse return;`
pub fn content(self: *const Layout, position: model.Position) ?*const model.Content {
    return switch (self.slot(position).*) {
        .content => |*value| value,
        else => null,
    };
}

pub fn panel(self: *const Layout, index: u8) ?*const PanelHeading {
    if (index >= self.panel_count) {
        return null;
    }

    return &self.panels[index];
}

pub fn isLive(self: *const Layout, position: model.Position) bool {
    return self.live_mask & position.bit() != 0;
}

pub fn set(self: *Layout, position: model.Position, slot_value: model.Slot) void {
    switch (position) {
        .bottom_left => self.bottom[0] = slot_value,
        .bottom_center => self.bottom[1] = slot_value,
        .bottom_right => self.bottom[2] = slot_value,
        .top_right => self.top_right = slot_value,
        .sidebar_footer_left => self.sidebar_footer[0] = slot_value,
        .sidebar_footer_center => self.sidebar_footer[1] = slot_value,
        .sidebar_footer_right => self.sidebar_footer[2] = slot_value,
    }
}

pub fn eql(self: *const Layout, right: *const Layout) bool {
    if (self.generation != right.generation or self.live_mask != right.live_mask) {
        return false;
    }
    if (self.panel_count != right.panel_count) {
        return false;
    }
    for (self.panels[0..self.panel_count], right.panels[0..right.panel_count]) |left_panel, right_panel| {
        if (!std.meta.eql(left_panel, right_panel)) {
            return false;
        }
    }
    inline for (std.meta.fields(model.Position)) |field| {
        const position: model.Position = @enumFromInt(field.value);
        if (!model.slotEql(self.slot(position), right.slot(position))) {
            return false;
        }
    }

    return true;
}
