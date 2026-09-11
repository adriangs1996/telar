//! Owns the replaceable timer used by the client notification lifecycle.

const Client = @import("../Client.zig");
const monotonic_module = @import("telar-client").monotonic;
const wait_module = @import("telar-client").wait;

/// Replaces the pending deadline from current model state and starts at most
/// one client select task.
///
/// ```zig
/// try reschedule(client);
/// ```
pub fn reschedule(client: *Client) !void {
    const scheduler = &client.notification_scheduler;
    const now_ns = monotonic_module(client.io);
    const deadline_ns = client.model.nextNotificationDeadline(
        now_ns,
        client.presenter.pacer.interval,
    );
    switch (scheduler.update(client.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.select.concurrent(.notification_tick, wait_module, .{
            client.io,
            scheduler,
        }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

/// Releases the completed select task before propagating its result.
///
/// ```zig
/// try complete(client, result);
/// ```
pub fn complete(client: *Client, result: anyerror!void) !void {
    try client.notification_scheduler.complete(result);
}
