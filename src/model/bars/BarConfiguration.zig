const model = @import("model.zig");
const Layout = @import("BarLayout.zig");
const std = @import("std");
const Configuration = @This();

bottom: [3]model.Source = .{ .metrics, .empty, .tabs },
top_right: model.Source = .empty,
/// Left-to-right slots of the sidebar footer row; tabs are never accepted here.
sidebar_footer: [3]model.Source = .{ .metrics, .empty, .empty },

pub fn source(self: *const Configuration, position: model.Position) *const model.Source {
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

pub fn presentation(self: *const Configuration) Layout {
    var result: Layout = .{};
    inline for (std.meta.fields(model.Position)) |field| {
        const position: model.Position = @enumFromInt(field.value);
        result.set(position, model.presentationSlot(self.source(position)));
        switch (self.source(position).*) {
            .dynamic => |value| {
                result.generation = value.callback.generation;
                result.live_mask |= position.bit();
            },
            .command => |value| {
                result.generation = value.generation;
                result.live_mask |= position.bit();
            },
            else => {},
        }
    }

    return result;
}
