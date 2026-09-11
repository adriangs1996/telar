const Hints = @import("Hints.zig");

pub const max_prefix_hints = 8;

pub const Mode = union(enum) {
    normal,
    prefix: Hints,
    copy,
};
