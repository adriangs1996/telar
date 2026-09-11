const Configuration = @This();
const source_namespace = @import("model.zig");
const Layout = @import("Layout.zig");
const std = @import("std");
bottom: [3]source_namespace.Source = .{ .metrics, .empty, .tabs },
top_right: source_namespace.Source = .empty,

pub fn source(configuration: *const Configuration, position: source_namespace.Position) *const source_namespace.Source {
    return switch (position) {
        .bottom_left => &configuration.bottom[0],
        .bottom_center => &configuration.bottom[1],
        .bottom_right => &configuration.bottom[2],
        .top_right => &configuration.top_right,
    };
}

pub fn presentation(configuration: *const Configuration) Layout {
    var result: Layout = .{};
    inline for (std.meta.fields(source_namespace.Position)) |field| {
        const position: source_namespace.Position = @enumFromInt(field.value);
        result.set(position, source_namespace.presentationSlot(configuration.source(position)));
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
