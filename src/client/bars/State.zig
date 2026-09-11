const State = @This();
const Layout = @import("Layout.zig");
const source_namespace = @import("model.zig");
const Update = @import("Update.zig");
layout: Layout = .{},

pub fn init(layout: Layout) State {
    return .{ .layout = layout };
}

pub fn replace(state: *State, layout: Layout) source_namespace.Change {
    if (state.layout.eql(&layout)) {
        return .unchanged;
    }

    state.layout = layout;
    return .changed;
}

pub fn update(state: *State, update_value: Update) !source_namespace.Change {
    if (state.layout.generation != update_value.generation or !state.layout.isLive(update_value.position)) {
        return error.StaleBarUpdate;
    }

    const current = state.layout.slot(update_value.position);
    if (current.* != .content) {
        return error.InvalidBarUpdateTarget;
    }
    if (current.content.eql(&update_value.content)) {
        return .unchanged;
    }

    state.layout.set(update_value.position, .{ .content = update_value.content });
    return .changed;
}
