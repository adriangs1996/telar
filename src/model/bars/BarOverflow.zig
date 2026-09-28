//! The top-level bar components a fitted row had no room for, in order. The
//! row records them while drawing; the overflow panel lists them.
const BarComponent = @import("BarComponent.zig");
const bar_values = @import("model.zig");
const BarOverflow = @This();

pub const capacity = 4 * bar_values.max_bar_nodes;

items: [capacity]BarComponent = undefined,
count: usize = 0,

pub fn append(self: *BarOverflow, component: BarComponent) void {
    if (self.count == capacity) {
        return;
    }

    self.items[self.count] = component;
    self.count += 1;
}

pub fn slice(self: *const BarOverflow) []const BarComponent {
    return self.items[0..self.count];
}
