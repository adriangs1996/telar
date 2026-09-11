const keybind = @import("root.zig").keybind;

pub const max_prefix_hints = 8;

pub const Hint = @import("Hint.zig");

pub const Hints = @import("Hints.zig");

pub const Mode = union(enum) {
    normal,
    prefix: Hints,
    copy,
};
