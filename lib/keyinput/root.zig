//! Keys as values: codes, characters, modifiers, press phases and physical
//! identities; chord text such as "ctrl+b" parsed into keys; the order
//! bindings sort by; bounded binding sequences and physical-key leases;
//! mouse events; a keymap and router that turn keys and terminal bytes into
//! actions, replays or forwarded input; and the bytes a child application
//! expects for a key, a paste or a mouse event under the modes it enabled.
//! What a key means is the caller's.

const encoding = @import("encoding.zig");
const mouse_protocol = @import("mouse_protocol.zig");

pub const Char = @import("Char.zig");
pub const Control = @import("Control.zig").Control;
pub const GenericBinding = @import("GenericBinding.zig").Type;
pub const GenericKeymap = @import("GenericKeymap.zig").Type;
pub const GenericRouter = @import("GenericRouter.zig").Type;
pub const GenericTable = @import("GenericTable.zig").Type;
pub const InputModes = @import("InputModes.zig");
pub const Key = @import("Key.zig");
pub const Mouse = @import("Mouse.zig");
pub const MouseTracking = @import("MouseTracking.zig").MouseTracking;
pub const PixelProjection = @import("PixelProjection.zig");
pub const Physical = @import("Physical.zig");
pub const RepeatPolicy = @import("RepeatPolicy.zig");
pub const RouterLimits = @import("RouterLimits.zig");
pub const chord = @import("chord.zig");
pub const keybind = @import("keybind.zig");
pub const encodeKey = encoding.encodeKey;
pub const encodePaste = encoding.encodePaste;
pub const encodeSgr = mouse_protocol.encodeSgr;
pub const tracked = mouse_protocol.tracked;

test {
    _ = @import("Char.zig");
    _ = @import("Control.zig");
    _ = @import("GenericBinding.zig");
    _ = @import("GenericKeymap.zig");
    _ = @import("GenericRouter.zig");
    _ = @import("GenericTable.zig");
    _ = @import("InputModes.zig");
    _ = @import("Key.zig");
    _ = @import("KittyCodepoints.zig");
    _ = @import("Mods.zig");
    _ = @import("Mouse.zig");
    _ = @import("MouseTracking.zig");
    _ = @import("PixelProjection.zig");
    _ = @import("Physical.zig");
    _ = @import("RepeatPolicy.zig");
    _ = @import("RouterLimits.zig");
    _ = @import("RoutingCapture.zig");
    _ = @import("chord.zig");
    _ = @import("encoding.zig");
    _ = @import("encoding_tests.zig");
    _ = @import("keybind.zig");
    _ = @import("mouse_protocol.zig");
    _ = @import("key_tests.zig");
    _ = @import("routing_tests.zig");
}
