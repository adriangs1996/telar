//! Work the shared client asks its adapter to run off the event loop on the
//! interactive path: runtime reads and writes, and deadline timers. Every
//! variant is a few words that point at client-owned state, so queueing and
//! starting one copies a cache line, not a request. Jobs that carry a copy
//! of their request are `BackgroundJob`s. Every job completes as one
//! `Message`; `job_runner.run` executes it.
const pacing = @import("pacing");
const RuntimeTransportState = @import("../connection/RuntimeTransportState.zig");

pub const Job = union(enum) {
    runtime_read: *RuntimeTransportState,
    runtime_send: RuntimeSend,
    /// Waits for a client deadline; the timer names the completion.
    timer: Timer,

    pub const RuntimeSend = struct {
        state: *RuntimeTransportState,
        /// Owned by `state` until the send completes.
        bytes: []const u8,
    };

    pub const Timer = struct {
        kind: Kind,
        scheduler: *pacing.DeadlineScheduler,
    };

    pub const Kind = enum {
        bar,
        notification,
        sidebar_animation,
    };
};
