const keybind = @import("root.zig").keybind;

pub const max_prefix_hints = 8;

pub const Hint = struct {
    key: keybind.Key,
    label: []const u8,
};

pub const Hints = struct {
    items: [max_prefix_hints]Hint = undefined,
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
};

pub const Mode = union(enum) {
    normal,
    prefix: Hints,
    copy,
};
