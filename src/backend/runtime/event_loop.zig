//! Bounded event-loop storage and stop-signal coordination.

const client_store = @import("client/store_support.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const std = @import("std");

pub const event_capacity = 16 + 2 * client_store.max_clients + 7 * max_panes_per_tab;

test "event storage covers every bounded actor slot" {
    try std.testing.expectEqual(
        @as(usize, 16 + 2 * client_store.max_clients + 7 * max_panes_per_tab),
        event_capacity,
    );
}
