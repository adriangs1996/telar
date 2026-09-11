//! Bounded event-loop storage and stop-signal coordination.

const std = @import("std");
const pane = @import("../pane/root.zig");
const client_store = @import("client/root.zig").store;
const runtime_event = @import("event.zig");
const stop_signal = @import("lifecycle/root.zig").stop_signal;

pub const Io = std.Io;

pub const Event = runtime_event.Event;
pub const event_capacity = 16 + 2 * client_store.max_clients + 7 * pane.max_panes;

pub const Loop = @import("Loop.zig");

test "event storage covers every bounded actor slot" {
    try std.testing.expectEqual(
        @as(usize, 16 + 2 * client_store.max_clients + 7 * pane.max_panes),
        event_capacity,
    );
}
