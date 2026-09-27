//! A client's link to its machine's runtime (docs/flows/runtime-link.md).
//! The client connects off the event loop, adopts the socket, and when a
//! read or write fails it keeps running: the chrome shows the link as lost,
//! the socket closes once no job uses it, and a new attempt follows after a
//! capped backoff. The next session starts as a fresh client would.
const data = @import("model");
const pacing = @import("pacing");
const std = @import("std");
const Client = @import("../execution/Client.zig");
const RuntimeConnectJob = @import("RuntimeConnectJob.zig");
const MachineTarget = @import("../machines/MachineTarget.zig").MachineTarget;
const machine_connection = @import("../machines/machine_connection.zig");
const runtime_io = @import("runtime_io.zig");
const pane_closure = @import("../panes/pane_closure.zig");
const client_tests = @import("../execution/client_tests.zig");

/// Waits between attempts: the first retry after half a second, doubling up
/// to thirty seconds.
const first_retry_ms = 500;
const longest_retry_ms = 30 * std.time.ms_per_s;
/// A link that stayed up this long earns fast retries again.
const healthy_after_ns = 60 * std.time.ns_per_s;
/// Doublings after which the wait stops growing.
const max_backoff_doublings = 16;

/// Starts the first connection once the adapter's host is ready. The
/// adapter stores its bootstrap first; every session sends it.
///
/// ```zig
/// client.bootstrap = .{ .graphics_shared = false, .client_identity = identity, .terminal_colors = colors };
/// try runtime_link.start(client);
/// ```
pub fn start(client: *Client) !void {
    const target = client.options.machine orelse return error.NoMachineTarget;
    const link = &client.model.runtime_link;
    link.name(targetName(target));
    link.phase = .connecting;
    link.clearFailure();
    client.model.link_revision +%= 1;

    // A job already running reached the old target; its result is closed
    // when it lands, and the new attempt starts then.
    if (client.connect_pending) {
        client.connect_outdated = true;
        return;
    }

    try queueConnect(client, target);
}

/// Runs one attempt on a worker. It fills the job's slots and returns the
/// completion the client handles in `finishConnect`.
///
/// ```zig
/// const result = runtime_link.runConnect(io, gpa, job);
/// ```
pub fn runConnect(io: std.Io, gpa: std.mem.Allocator, job: RuntimeConnectJob) anyerror!void {
    var writer: std.Io.Writer = .fixed(&job.report.bytes);
    defer job.report.len = writer.end;

    job.connection.* = try machine_connection.connect(io, gpa, job.environ, job.target, &writer);
}

/// Takes a finished attempt: adopts its connection, or records why it
/// failed and waits to try again.
///
/// ```zig
/// try runtime_link.finishConnect(client, result);
/// ```
pub fn finishConnect(client: *Client, result: anyerror!void) !void {
    client.connect_pending = false;

    // A machine the window stopped, or whose target changed meanwhile,
    // keeps no connection that arrives late.
    const outdated = client.connect_outdated;
    client.connect_outdated = false;
    if (client.model.runtime_link.phase == .stopped or outdated) {
        if (result) |_| {
            var connection = client.connect_result;
            connection.channel.deinit(client.io);
            if (connection.forward) |*forward| {
                forward.stop(client.io);
            }
        } else |_| {}

        if (outdated and client.model.runtime_link.phase == .connecting) {
            try queueConnect(client, client.options.machine.?);
        }

        return;
    }

    result catch |err| {
        const report = client.connect_report.text();
        client.model.runtime_link.fail(if (report.len != 0) report else @errorName(err));
        client.model.runtime_link.phase = .lost;
        client.model.link_revision +%= 1;

        return scheduleRetry(client);
    };

    try adopt(client);
}

/// Records that the socket failed. The client keeps running: queued
/// messages are dropped, the SSH forward stops, the socket closes once no
/// read or write uses it, and a new attempt is scheduled. A client handed
/// its socket by the adapter cannot reconnect, so the failure ends it.
///
/// ```zig
/// try runtime_link.lose(client, err);
/// ```
pub fn lose(client: *Client, err: anyerror) !void {
    if (client.options.machine == null) {
        return err;
    }

    const link = &client.model.runtime_link;
    if (link.phase != .connected) {
        closeWhenIdle(client);
        return;
    }

    const now_ns = pacing.clock.monotonic(client.io);
    if (now_ns -| client.connected_at_ns >= healthy_after_ns) {
        link.attempt = 0;
    }

    link.phase = .lost;
    link.fail(@errorName(err));
    client.model.link_revision +%= 1;
    client.model.to_runtime.discardQueued();

    // Shutting the socket down makes a read or write still waiting on it
    // return, without releasing the descriptor under it.
    if (client.channel_owned) {
        client.channel.shutdown(client.io);
    }

    if (client.forward) |*forward| {
        forward.stop(client.io);
        client.forward = null;
    }

    closeWhenIdle(client);
    try scheduleRetry(client);
}

/// Stops keeping the machine connected: the socket shuts down and closes
/// once idle, the forward stops, and no retry follows. `start` connects it
/// again. The runtime and its panes are untouched.
///
/// ```zig
/// runtime_link.stop(client);
/// ```
pub fn stop(client: *Client) void {
    const link = &client.model.runtime_link;
    link.phase = .stopped;
    link.clearFailure();
    client.model.link_revision +%= 1;
    client.model.to_runtime.discardQueued();
    if (client.channel_owned) {
        client.channel.shutdown(client.io);
    }

    if (client.forward) |*forward| {
        forward.stop(client.io);
        client.forward = null;
    }

    closeWhenIdle(client);
}

/// Closes a lost socket once no read or write uses it. Closing earlier could
/// let the descriptor number be reused under a job still waiting on it.
///
/// ```zig
/// runtime_link.closeWhenIdle(client);
/// ```
pub fn closeWhenIdle(client: *Client) void {
    if (client.model.runtime_link.phase == .connected) {
        return;
    }

    if (client.runtime_transport.receive_pending or client.model.to_runtime.inFlight()) {
        return;
    }

    client.runtime_transport.unbind();
    if (client.channel_owned) {
        client.channel.deinit(client.io);
        client.channel_owned = false;
    }
}

/// Starts the next attempt when the backoff ends, unless the old socket is
/// still in use; then it waits once more.
///
/// ```zig
/// try runtime_link.retry(client, result);
/// ```
pub fn retry(client: *Client, result: anyerror!void) !void {
    try client.runtime_retry.complete(result);

    const link = &client.model.runtime_link;
    if (link.phase != .lost) {
        return;
    }

    if (client.channel_owned) {
        return scheduleRetry(client);
    }

    link.phase = .connecting;
    link.attempt +|= 1;
    client.model.link_revision +%= 1;
    try queueConnect(client, client.options.machine.?);
}

fn queueConnect(client: *Client, target: MachineTarget) !void {
    client.connect_report.len = 0;
    client.connect_pending = true;
    errdefer client.connect_pending = false;
    try client.to_background.push(.{ .runtime_connect = .{
        .target = target,
        .environ = client.options.environ,
        .connection = &client.connect_result,
        .report = &client.connect_report,
    } });
}

fn scheduleRetry(client: *Client) !void {
    const shift: u5 = @intCast(@min(client.model.runtime_link.attempt, max_backoff_doublings));
    const delay_ms: u64 = @min(@as(u64, first_retry_ms) << shift, longest_retry_ms);
    const deadline_ns = pacing.clock.monotonic(client.io) + delay_ms * std.time.ns_per_ms;
    const scheduler = &client.runtime_retry;
    switch (scheduler.update(client.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.to_workers.push(.{ .timer = .{ .kind = .runtime_retry, .scheduler = scheduler } }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

fn adopt(client: *Client) !void {
    const connection = client.connect_result;
    const link = &client.model.runtime_link;
    if (link.sessions != 0) {
        forgetSession(client);
    }

    // A new session opens its first pane again when shown.
    client.open_deferred = false;
    client.deferred_layout = null;
    client.left_workspace = null;
    client.leave_pending = false;

    client.channel = connection.channel;
    client.channel_owned = true;
    client.forward = connection.forward;
    client.runtime_transport.bind(&client.channel);
    client.connected_at_ns = pacing.clock.monotonic(client.io);
    adoptLaunchDefaults(client);

    // `--fresh` sets the first session aside; a reconnect adopts the runtime
    // that session started.
    if (client.options.machine) |*machine| {
        switch (machine.*) {
            .local => |*selection| selection.fresh = false,
            .remote => {},
        }
    }

    link.phase = .connected;
    link.sessions +|= 1;
    link.clearFailure();
    client.model.link_revision +%= 1;
    client.model.startup.phase = .opening;

    const bootstrap = client.bootstrap orelse return error.MissingRuntimeBootstrap;
    try client.model.to_runtime.pushBootstrap(bootstrap);
    try runtime_io.startRuntimeIo(client);
}

// Releases what the adapter holds for each pane of the lost session, then
// drops the session itself.
fn forgetSession(client: *Client) void {
    for (client.model.panes.record) |slot| {
        const pane = slot orelse continue;
        pane_closure.releasePaneResources(client, pane.id);
    }

    data.runtime_session.forget(&client.model);
}

// A remote machine launches the first pane in its own home, with the
// command the user named for it or its login shell.
fn adoptLaunchDefaults(client: *Client) void {
    const forward = client.forward orelse return;
    const defaults = forward.discovery.launchDefaults();
    const home = defaults.cwd[0..@min(defaults.cwd.len, client.launch_cwd.len)];
    @memcpy(client.launch_cwd[0..home.len], home);
    client.options.cwd = client.launch_cwd[0..home.len];

    const named = switch (client.options.machine.?) {
        .remote => |machine| machine.arguments,
        .local => &.{},
    };
    client.options.arguments = named;
    if (named.len == 0) {
        const shell = defaults.shell[0..@min(defaults.shell.len, client.launch_shell.len)];
        @memcpy(client.launch_shell[0..shell.len], shell);
        client.launch_arguments[0] = client.launch_shell[0..shell.len];
        client.options.arguments = &client.launch_arguments;
    }
}

fn targetName(target: MachineTarget) []const u8 {
    return switch (target) {
        .local => "this machine",
        .remote => |machine| machine.destination,
    };
}

test "a lost runtime is reached again and its session starts fresh" {
    try client_tests.reconnectAfterLoss(start);
}

test "a failed attempt shows its report and waits to retry" {
    try client_tests.failedAttemptWaits(start);
}
