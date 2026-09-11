const Layout = @This();
const source_namespace = @import("model.zig");
const std = @import("std");
generation: u64 = 0,
live_mask: u8 = 0,
bottom: [3]source_namespace.Slot = .{ .metrics, .empty, .tabs },
top_right: source_namespace.Slot = .empty,

pub fn slot(layout: *const Layout, position: source_namespace.Position) *const source_namespace.Slot {
    return switch (position) {
        .bottom_left => &layout.bottom[0],
        .bottom_center => &layout.bottom[1],
        .bottom_right => &layout.bottom[2],
        .top_right => &layout.top_right,
    };
}

pub fn isLive(layout: *const Layout, position: source_namespace.Position) bool {
    return layout.live_mask & position.bit() != 0;
}

pub fn set(layout: *Layout, position: source_namespace.Position, slot_value: source_namespace.Slot) void {
    switch (position) {
        .bottom_left => layout.bottom[0] = slot_value,
        .bottom_center => layout.bottom[1] = slot_value,
        .bottom_right => layout.bottom[2] = slot_value,
        .top_right => layout.top_right = slot_value,
    }
}

pub fn eql(left: *const Layout, right: *const Layout) bool {
    if (left.generation != right.generation or left.live_mask != right.live_mask) {
        return false;
    }
    inline for (std.meta.fields(source_namespace.Position)) |field| {
        const position: source_namespace.Position = @enumFromInt(field.value);
        if (!source_namespace.slotEql(left.slot(position), right.slot(position))) {
            return false;
        }
    }

    return true;
}
