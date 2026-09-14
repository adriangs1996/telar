//! Owns the replaceable timer used by the client notification lifecycle.

const Client = @import("../AttachedClient.zig");
const monotonic_module = @import("clock.zig").monotonic;

/// Replaces the pending deadline from current model state and starts at most
/// one inbox producer through the timer port.
///
/// ```zig
/// try reschedule(client);
/// ```
pub fn reschedule(client: *Client) !void {
    const scheduler = &client.notification_scheduler;
    const now_ns = monotonic_module(client.io);
    const deadline_ns = client.model.nextNotificationDeadline(
        now_ns,
        if (client.timers.animation_clock == .host) @import("std").math.maxInt(u64) else client.presentation.frameIntervalNs(),
    );
    switch (scheduler.update(client.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.timers.arm(.notification, scheduler) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

/// Releases the completed timer reservation before propagating its result.
///
/// ```zig
/// try complete(client, result);
/// ```
pub fn complete(client: *Client, result: anyerror!void) !void {
    try client.notification_scheduler.complete(result);
}
