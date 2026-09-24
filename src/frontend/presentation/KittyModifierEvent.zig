const keyinput = @import("keyinput");
const screen_support = @import("screen_support.zig");
const KittyModifierEvent = @This();

modifier: u32,
event: keyinput.Key.Phase,
