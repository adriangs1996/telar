const Layout = @import("BarLayout.zig");
const model = @import("model.zig");
const Update = @import("Update.zig");
const State = @This();

layout: Layout = .{},

pub fn init(layout: Layout) State {
    return .{ .layout = layout };
}

pub fn replace(self: *State, layout: Layout) model.Change {
    if (self.layout.eql(&layout)) {
        return .unchanged;
    }

    self.layout = layout;
    return .changed;
}

pub fn update(self: *State, update_value: Update) !model.Change {
    if (self.layout.generation != update_value.generation or !self.layout.isLive(update_value.position)) {
        return error.StaleBarUpdate;
    }

    const current = self.layout.slot(update_value.position);
    if (current.* != .content) {
        return error.InvalidBarUpdateTarget;
    }
    if (current.content.eql(&update_value.content)) {
        return .unchanged;
    }

    self.layout.set(update_value.position, .{ .content = update_value.content });
    return .changed;
}
