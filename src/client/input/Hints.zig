const keyinput = @import("keyinput");
const hints_support = @import("hints_support.zig");
const Hints = @This();

// SAFETY: append writes each hint before increasing len; slice exposes only that initialized prefix.
items: [hints_support.max_prefix_hints]Hint = undefined,
len: u8 = 0,

pub fn append(self: *Hints, hint: Hint) void {
    if (self.len == self.items.len) {
        return;
    }
    self.items[self.len] = hint;
    self.len += 1;
}

pub fn slice(self: *const Hints) []const Hint {
    return self.items[0..self.len];
}

const Hint = struct {
    key: keyinput.Key,
    label: []const u8,
};
