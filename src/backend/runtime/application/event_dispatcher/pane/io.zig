//! Runtime-event adapters for bounded writes into pane PTYs.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../../pane/root.zig");
const pane_events = @import("../../../entrypoints/events/pane/root.zig");

pub const diagnostics = core.diagnostics;

pub const Pane = pane_mod.Pane;
pub const pane_input_pump = pane_events.input;
pub const pane_response_pump = pane_events.response;
pub const PaneInputEvent = pane_input_pump.Completion;
pub const PaneResponseEvent = pane_response_pump.Completion;

pub const Dispatcher = @import("GenericIoDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
