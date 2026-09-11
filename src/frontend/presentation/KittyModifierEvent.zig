const screen_support = @import("screen_support.zig");
const KittyModifierEvent = @This();

modifier: u32,
event: screen_support.Event.Key.Phase,
