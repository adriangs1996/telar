//! Keys as values: codes, characters, modifiers, press phases and physical
//! identities; chord text such as "ctrl+b" parsed into keys; the order
//! bindings sort by; bounded binding sequences and physical-key leases;
//! mouse events; and a keymap and router that turn keys and terminal bytes
//! into actions, replays or forwarded input. What a key means is the caller's.

pub const Char = @import("Char.zig");
pub const Control = @import("Control.zig").Control;
pub const GenericBinding = @import("GenericBinding.zig").Type;
pub const GenericKeymap = @import("GenericKeymap.zig").Type;
pub const GenericRouter = @import("GenericRouter.zig").Type;
pub const GenericTable = @import("GenericTable.zig").Type;
pub const Key = @import("Key.zig");
pub const Mouse = @import("Mouse.zig");
pub const Physical = @import("Physical.zig");
pub const RepeatPolicy = @import("RepeatPolicy.zig");
pub const RouterLimits = @import("RouterLimits.zig");
pub const chord = @import("chord.zig");
pub const keybind = @import("keybind.zig");

test {
    _ = @import("Char.zig");
    _ = @import("Control.zig");
    _ = @import("GenericBinding.zig");
    _ = @import("GenericKeymap.zig");
    _ = @import("GenericRouter.zig");
    _ = @import("GenericTable.zig");
    _ = @import("Key.zig");
    _ = @import("KittyCodepoints.zig");
    _ = @import("Mods.zig");
    _ = @import("Mouse.zig");
    _ = @import("Physical.zig");
    _ = @import("RepeatPolicy.zig");
    _ = @import("RouterLimits.zig");
    _ = @import("RoutingCapture.zig");
    _ = @import("chord.zig");
    _ = @import("keybind.zig");
    _ = @import("key_tests.zig");
    _ = @import("routing_tests.zig");
}
