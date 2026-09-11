const Hints = @This();
const source_namespace = @import("hints_support.zig");
const Hint = @import("Hint.zig");
items: [source_namespace.max_prefix_hints]Hint = undefined,
len: u8 = 0,

pub fn append(hints: *Hints, hint: Hint) void {
    if (hints.len == hints.items.len) {
        return;
    }
    hints.items[hints.len] = hint;
    hints.len += 1;
}

pub fn slice(hints: *const Hints) []const Hint {
    return hints.items[0..hints.len];
}
