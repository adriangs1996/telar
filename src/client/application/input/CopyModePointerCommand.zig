const Mouse = @import("../../input/Mouse.zig");
const Command = @This();

kind: Mouse.Kind,
left_button: bool = true,
