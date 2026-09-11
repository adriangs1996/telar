const Layout = @import("BarLayout.zig");
const model = @import("model.zig");
const Update = @import("Update.zig");
const State = @This();

layout: Layout = .{},

pub fn init(layout: Layout) State {
    return .{ .layout = layout };
}

pub fn replace(state: *State, layout: Layout) model.Change {
    if (state.layout.eql(&layout)) {
        return .unchanged;
    }

    state.layout = layout;
    return .changed;
}

pub fn update(state: *State, update_value: Update) !model.Change {
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
