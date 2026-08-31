//! Bounded event-loop storage and stop-signal coordination.

const std = @import("std");
const pane = @import("../pane/root.zig");
const client_store = @import("client/root.zig").store;
const runtime_event = @import("event.zig");
const stop_signal = @import("lifecycle/root.zig").stop_signal;

const Io = std.Io;

pub const Event = runtime_event.Event;
const event_capacity = 16 + 2 * client_store.max_clients + 7 * pane.max_panes;

/// Owns the bounded selector and external stop coordination for one runtime.
pub const Loop = struct {
    stop_signal: stop_signal.Coordinator,
    storage: [event_capacity]Event,
    select: Io.Select(Event),

    /// Initializes bounded event storage without starting any actor.
    ///
    /// ```zig
    /// var loop: Loop = undefined;
    /// loop.init(io, stop_queue);
    /// ```
    pub fn init(loop: *Loop, io: Io, stop: ?*Io.Queue(u8)) void {
        loop.stop_signal = .init(stop);
        loop.select = Io.Select(Event).init(io, &loop.storage);
    }

    /// Returns the selector borrowed by runtime event sources and dispatchers.
    ///
    /// ```zig
    /// const select = loop.selector();
    /// ```
    pub fn selector(loop: *Loop) *Io.Select(Event) {
        return &loop.select;
    }

    /// Returns the coordinator used to arm and complete the stop source.
    ///
    /// ```zig
    /// const stop = loop.stopCoordinator();
    /// ```
    pub fn stopCoordinator(loop: *Loop) *stop_signal.Coordinator {
        return &loop.stop_signal;
    }

    /// Waits until one scheduled actor produces an event.
    ///
    /// ```zig
    /// const event = try loop.next();
    /// ```
    pub fn next(loop: *Loop) !Event {
        return loop.select.await();
    }

    /// Completes the injected or platform stop source.
    ///
    /// ```zig
    /// if (try loop.completeStop(result)) return;
    /// ```
    pub fn completeStop(loop: *Loop, result: anyerror!void) !bool {
        return switch (try loop.stop_signal.complete(result)) {
            .stop => true,
        };
    }

    /// Cancels every scheduled actor and discards pending completions.
    ///
    /// ```zig
    /// loop.cancel();
    /// ```
    pub fn cancel(loop: *Loop) void {
        loop.select.cancelDiscard();
    }
};

test "event storage covers every bounded actor slot" {
    try std.testing.expectEqual(
        @as(usize, 16 + 2 * client_store.max_clients + 7 * pane.max_panes),
        event_capacity,
    );
}
