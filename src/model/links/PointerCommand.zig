const pointer_support = @import("pointer_support.zig");
const Command = @This();

kind: PointerSupportKind,
left_button: bool,
right_button: bool = false,

const PointerSupportKind = enum {
    press,
    release,
    drag,
    other,
};
