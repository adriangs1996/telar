const pointer_support = @import("pointer_support.zig");
const Command = @This();

kind: pointer_support.Kind,
left_button: bool,
