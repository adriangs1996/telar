const model = @import("model.zig");
const Layout = @import("BarLayout.zig");
const std = @import("std");
const Configuration = @This();

bottom: [3]model.Source = .{ .metrics, .empty, .tabs },
top_right: model.Source = .empty,

pub fn source(configuration: *const Configuration, position: model.Position) *const model.Source {
    return switch (position) {
        .bottom_left => &configuration.bottom[0],
        .bottom_center => &configuration.bottom[1],
        .bottom_right => &configuration.bottom[2],
        .top_right => &configuration.top_right,
    };
}

pub fn presentation(configuration: *const Configuration) Layout {
    var result: Layout = .{};
    inline for (std.meta.fields(model.Position)) |field| {
        const position: model.Position = @enumFromInt(field.value);
        result.set(position, model.presentationSlot(configuration.source(position)));
        switch (configuration.source(position).*) {
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
