//! Limit reached, client side: a limit this client or its window reached is
//! counted in `model.limit_reaches`, shown in this window at most once per
//! `limit_reached.show_interval_ms`, logged, and folded into one
//! `report_limit` a second so `telar diagnostics limits` lists it.
//!
//! Everything here runs on the thread that owns the client: the adapter's
//! event loop. A job never calls it: it returns the reach in its completion
//! and the flow that finishes it reports. See `docs/flows/limit-reached.md`.
const std = @import("std");
const core = @import("telar-core");
const Client = @import("../execution/Client.zig");
const notifications = @import("notifications.zig");
const runtime_link = @import("../connection/runtime_link.zig");
const RuntimeResync = @import("../connection/RuntimeResync.zig").RuntimeResync;
const pacing = @import("pacing");
const client_tests = @import("../execution/client_tests.zig");

const log = std.log.scoped(.limits);

/// How long a limit notice stays on screen.
const notice_duration_ns = 8 * std.time.ns_per_s;
/// Outbox slots a report leaves free, so input and requests never wait
/// behind one: a report goes only while more than this many are free.
const outbox_reserve = 8;
/// Resyncs for limits one link may ask for within
/// `runtime_link.healthy_after_ns`; one more gives the link up, since each
/// resync would stop at the same limit.
const max_limit_resyncs = 3;
/// Route of a runtime message that stopped at a limit while it was applied.
const message_route = "runtime_message";
/// Title of the notice for a graphics limit: the pane's images pause.
const paused_title = "Limit reached: images paused";

/// Counts one reach of a limit; shows it, logs it and reports it to the
/// runtime when its interval allows. Never fails and allocates nothing, so
/// it can sit where the limit is enforced.
///
/// ```zig
/// limit_reached.report(client, .{
///     .limit = core.Limit.declare("bars.max_bar_actions", "click actions", data.bar_values.max_bar_actions),
///     .requested = actions,
/// });
/// ```
pub fn report(client: *Client, reach: core.LimitReach) void {
    _ = notice(client, reach);
}

/// Reports the limits the active configuration generation reached where
/// it could not report them itself: while it loaded, or inside a callback.
/// One comparison when there are none; `Client.flush` calls it once per
/// event.
///
/// ```zig
/// limit_reached.reportGeneration(client);
/// ```
pub fn reportGeneration(client: *Client) void {
    const generation = client.lua_generation orelse return;
    const unreported = &generation.unreported;
    if (unreported.count == 0) {
        return;
    }

    for (unreported.slice()) |reach| {
        report(client, reach);
    }

    if (unreported.dropped != 0) {
        log.warn("{d} more configuration limits were reached and not listed", .{unreported.dropped});
    }

    unreported.clear();
}

/// The safety net of a presentation adapter: a limit error is reported
/// under `limit`, or under its own name when null, with `route`, and the
/// caller keeps what it has. Any other error returns; a host error is
/// logged as an error first. The route line is logged with the notice, so
/// a limit reached every frame logs once a minute. A route a report could
/// not carry fails the build.
///
/// ```zig
/// try limit_reached.absorb(gui.app, "window_draw", err, null);
/// ```
pub fn absorb(client: *Client, comptime route: []const u8, err: anyerror, limit: ?core.Limit) anyerror!void {
    comptime {
        const routed: core.LimitReach = .{
            .limit = .{
                .name = "route",
                .value = 0,
            },
            .route = route,
        };
        routed.validate() catch |invalid| @compileError("limit route '" ++ route ++ "': " ++ @errorName(invalid));
    }

    if (!core.limit_reached.isLimitError(err)) {
        if (core.limit_reached.isSystemError(err)) {
            log.err("{s} failed on the host: {s}", .{ route, @errorName(err) });
        }

        return err;
    }

    var reach = core.limit_reached.unnamed(err, route);
    if (limit) |named| {
        reach.limit = named;
    }

    if (notice(client, reach)) {
        log.warn("{s} stopped at a limit: {s}", .{ route, @errorName(err) });
    }
}

/// The resync a runtime message that stopped at a limit needs, read from
/// the message while its buffer is still valid.
///
/// ```zig
/// const resync = limit_reached.plan(message);
/// ```
pub fn plan(message: *const core.ServerMessage) RuntimeResync {
    return switch (message.*) {
        .graphics_image => |value| .{ .graphics = value.pane_id },
        .graphics_shared_image => |value| .{ .graphics = value.pane_id },
        .graphics_image_chunk => |value| .{ .graphics = value.pane_id },
        .graphics_placement => |value| .{ .graphics = value.pane_id },
        .graphics_delete_image => |value| .{ .graphics = value.pane_id },
        .graphics_delete_placement => |value| .{ .graphics = value.pane_id },
        .graphics_snapshot => |value| .{ .graphics = value.pane_id },
        .pane_frame => |frame| .{ .pane = frame.pane_id },
        else => .session,
    };
}

/// Recovers from a runtime message that stopped at a limit while it was
/// applied, which may have left the replica short of the runtime. The limit
/// is reported, then the smallest resync the protocol has follows:
/// - graphics: the store paused that pane's stream at the limit; the notice
///   says the pane's images paused, and a graphics snapshot resumes it,
///   within the pane's own budget (`pauseGraphics`);
/// - a pane frame: a snapshot of that pane;
/// - anything else: a new session, which rebuilds the replica.
/// A link asking for more than `max_limit_resyncs` pane snapshots or new
/// sessions within `runtime_link.healthy_after_ns` gives the link up naming
/// the limit. A
/// resync that cannot be asked for loses the link, so the replica never
/// stays wrong while the link shows connected.
///
/// ```zig
/// try limit_reached.recover(client, limit_reached.plan(message), err);
/// ```
pub fn recover(client: *Client, resync: RuntimeResync, err: anyerror) !void {
    const reach = core.limit_reached.unnamed(err, message_route);
    if (resync == .graphics) {
        _ = noticeTitled(client, reach, paused_title);
        return pauseGraphics(client, resync.graphics);
    }

    report(client, reach);
    if (!admitResync(client)) {
        var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
        return runtime_link.abandon(client, reach.describe(&buffer, 1));
    }

    ask(client, resync, err) catch |failed| try runtime_link.lose(client, failed);
}

/// Asks again for the graphics snapshot of every paused pane whose budget
/// window has passed, so a pane does not stay paused until the link
/// reconnects. One comparison when no pane waits; called once per runtime
/// message.
///
/// ```zig
/// limit_reached.resumeGraphics(client);
/// ```
pub fn resumeGraphics(client: *Client) void {
    const pauses = &client.model.graphics_pauses;
    if (pauses.waiting_count == 0) {
        return;
    }

    const now_ns = pacing.clock.monotonic(client.io);
    for (0..pauses.count) |slot| {
        if (!pauses.waiting[slot] or now_ns -| pauses.since_ns[slot] < runtime_link.healthy_after_ns) {
            continue;
        }

        pauses.resyncs[slot] = 1;
        pauses.since_ns[slot] = now_ns;
        pauses.setWaiting(slot, false);
        askGraphics(client, pauses.pane_id[slot]) catch pauses.setWaiting(slot, true);
    }
}

/// A pane's graphics paused at a limit: its own budget allows
/// `max_limit_resyncs` snapshots within `runtime_link.healthy_after_ns`,
/// then it waits for the window to pass (`resumeGraphics`). It never spends
/// the link's budget.
fn pauseGraphics(client: *Client, pane_id: core.PaneId) !void {
    const pauses = &client.model.graphics_pauses;
    const now_ns = pacing.clock.monotonic(client.io);
    const slot = pauses.find(pane_id) orelse pauses.add(pane_id, now_ns);
    if (now_ns -| pauses.since_ns[slot] >= runtime_link.healthy_after_ns) {
        pauses.resyncs[slot] = 0;
        pauses.since_ns[slot] = now_ns;
    }

    pauses.resyncs[slot] +|= 1;
    if (pauses.resyncs[slot] > max_limit_resyncs) {
        pauses.setWaiting(slot, true);
        return;
    }

    askGraphics(client, pane_id) catch |failed| try runtime_link.lose(client, failed);
}

fn askGraphics(client: *Client, pane_id: core.PaneId) !void {
    try client.model.to_runtime.push(.{
        .request_graphics_snapshot = .{
            .pane_id = pane_id,
        },
    });
}

fn ask(client: *Client, resync: RuntimeResync, err: anyerror) !void {
    switch (resync) {
        .graphics => |pane_id| try askGraphics(client, pane_id),
        .pane => |pane_id| {
            const pane = client.model.panes.find(pane_id) orelse return;
            try client.model.to_runtime.push(.{
                .request_snapshot = .{
                    .pane_id = pane_id,
                    .known_frame_id = pane.applied_frame_id,
                },
            });
        },
        .session => try runtime_link.lose(client, err),
    }
}

fn admitResync(client: *Client) bool {
    const link = &client.model.runtime_link;
    const now_ns = pacing.clock.monotonic(client.io);
    if (link.limit_resyncs == 0 or now_ns -| link.limit_resyncs_since_ns >= runtime_link.healthy_after_ns) {
        link.limit_resyncs = 0;
        link.limit_resyncs_since_ns = now_ns;
    }

    link.limit_resyncs +|= 1;
    return link.limit_resyncs <= max_limit_resyncs;
}

/// Records one reach and shows it when its interval allows; returns
/// whether it showed, so a caller logs its own detail only then.
fn notice(client: *Client, reach: core.LimitReach) bool {
    return noticeTitled(client, reach, core.limit_reached.notice_title);
}

fn noticeTitled(client: *Client, reach: core.LimitReach, title: []const u8) bool {
    const at: core.ReachTime = .{
        .awake_ms = std.Io.Timestamp.now(client.io, .awake).toMilliseconds(),
        .real_ms = std.Io.Timestamp.now(client.io, .real).toMilliseconds(),
    };
    const reaches = &client.model.limit_reaches;
    const recorded = core.limit_reached.record(reaches, reach, at, 1);
    send(client, recorded.slot, at.awake_ms);

    if (!recorded.show) {
        return false;
    }

    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    const text = reaches.reachAt(recorded.slot).describe(&buffer, reaches.hits[recorded.slot]);
    log.warn("{s}", .{text});
    notifications.publishNotificationNow(
        client,
        .{
            .level = .warning,
            .title = title,
            .message = text,
            .duration_ns = notice_duration_ns,
        },
    ) catch |err| log.warn("limit notice not shown: {s}", .{@errorName(err)});

    return true;
}

fn send(client: *Client, slot: usize, awake_ms: i64) void {
    if (client.model.to_runtime.availableCapacity() <= outbox_reserve) {
        return;
    }

    const reaches = &client.model.limit_reaches;
    const hits = core.limit_reached.takeReport(reaches, slot, awake_ms) orelse return;
    const reported: core.ReportLimit = .{
        .reach = reaches.reachAt(slot),
        .hits = hits,
    };

    client.model.to_runtime.pushEncoded(core.encodeReportLimit, reported) catch {
        core.limit_reached.restoreReport(reaches, slot, hits);
    };
}

test "a runtime message at a limit resyncs as little as it can and gives up past its budget" {
    try client_tests.recoverLimitedMessages(recover, resumeGraphics);
}
