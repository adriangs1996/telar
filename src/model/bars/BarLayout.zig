const model = @import("model.zig");
const std = @import("std");
const Layout = @This();

generation: u64 = 0,
live_mask: u8 = 0,
bottom: [3]model.Slot = .{ .metrics, .empty, .tabs },
top_right: model.Slot = .empty,
sidebar_footer: [3]model.Slot = .{ .metrics, .empty, .empty },

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
    inline for (std.meta.fields(model.Position)) |field| {
        const position: model.Position = @enumFromInt(field.value);
        if (!model.slotEql(self.slot(position), right.slot(position))) {
            return false;
        }
    }

    return true;
}
