const Machines = @This();

pub const capacity = 17;
pub const max_label_bytes = 32;

total: u8 = 0,
active: u8 = 0,
attention: [capacity]bool = @splat(false),
labels: [capacity][3]u8 = undefined,

pub fn count(self: *const Machines) usize {
    return self.total;
}

pub fn shown(self: *const Machines, slot: u8) bool {
    return slot < self.total;
}

pub fn label(self: *const Machines, slot: u8) []const u8 {
    return &self.labels[slot];
}

pub fn color(self: *const Machines, slot: u8) ?[]const u8 {
    _ = self;
    _ = slot;

    return null;
}

pub fn attentionElsewhere(self: *const Machines) bool {
    for (self.attention, 0..) |attention, slot| {
        if (slot < self.total and slot != self.active and attention) {
            return true;
        }
    }

    return false;
}
