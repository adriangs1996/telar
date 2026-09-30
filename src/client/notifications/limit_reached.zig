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
const data = @import("model");
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
/// Title of the notice for a graphics limit when the pane has no place in
/// a tab to name it by.
const paused_title = "Images paused";
/// What a pane is called when its foreground has no name, as its header
/// calls it.
const unnamed_pane = "shell";
/// Consecutive windows a paused pane may end waiting before its wait stops
/// doubling: 60 s, 120 s, 240 s, 480 s, then 16 minutes.
const max_pause_doublings = 4;

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
/// is counted, then the smallest resync the protocol has follows:
/// - graphics: the store paused that pane's stream at the limit; a notice
///   names the pane when its pause starts, and a graphics snapshot resumes
///   it, within the pane's own budget (`pauseGraphics`);
/// - a pane frame: a snapshot of that pane;
/// - anything else: a new session, which rebuilds the replica.
/// A link asking for more than `max_limit_resyncs` pane snapshots or new
/// sessions within `runtime_link.healthy_after_ns` gives the link up naming
/// the limit. A resync that cannot be asked for loses the link, so the
/// replica never stays wrong while the link shows connected.
///
/// ```zig
/// try limit_reached.recover(client, limit_reached.plan(message), err);
/// ```
pub fn recover(client: *Client, resync: RuntimeResync, err: anyerror) !void {
    const reach = core.limit_reached.unnamed(err, message_route);
    if (resync == .graphics) {
        return pauseGraphics(
            client,
            reach,
            resync.graphics,
        );
    }

    report(client, reach);
    if (!admitResync(client)) {
        var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
        return runtime_link.abandon(client, reach.describe(&buffer, 1));
    }

    ask(client, resync, err) catch |failed| try runtime_link.lose(client, failed);
}

/// Asks again for the graphics snapshot of every paused pane whose wait
/// has passed, then arms the timer for the next one. The timer, each
/// applied runtime message and a pane gaining focus call it, so a pane
/// resumes without runtime traffic. One comparison while no pane waits,
/// and no timer then.
///
/// ```zig
/// try limit_reached.resumeGraphics(client);
/// ```
pub fn resumeGraphics(client: *Client) !void {
    const pauses = &client.model.graphics_pauses;
    if (pauses.waiting_count == 0) {
        return;
    }

    const now_ns = pacing.clock.monotonic(client.io);
    for (0..pauses.count) |slot| {
        if (!pauses.waiting[slot] or now_ns < pauses.due_ns[slot]) {
            continue;
        }

        resumeRow(
            client,
            slot,
            now_ns,
        ) catch |failed| return runtime_link.lose(client, failed);
    }

    try scheduleResume(client);
}

/// A person focusing a paused pane brings it back to the base rate: once
/// `runtime_link.healthy_after_ns` passed since its window started, it
/// asks now instead of at the end of its doubled wait. The backoff stays,
/// since the pause did not end.
///
/// ```zig
/// try limit_reached.resumeFocused(client, pane_id);
/// ```
pub fn resumeFocused(client: *Client, pane_id: core.PaneId) !void {
    const pauses = &client.model.graphics_pauses;
    if (pauses.waiting_count == 0) {
        return;
    }

    const slot = pauses.find(pane_id) orelse return;
    const now_ns = pacing.clock.monotonic(client.io);
    if (!pauses.waiting[slot] or now_ns -| pauses.since_ns[slot] < runtime_link.healthy_after_ns) {
        return;
    }

    resumeRow(
        client,
        slot,
        now_ns,
    ) catch |failed| return runtime_link.lose(client, failed);
    try scheduleResume(client);
}

/// Takes the timer that waited for the earliest paused pane.
///
/// ```zig
/// try limit_reached.finishResumeTick(client, result);
/// ```
pub fn finishResumeTick(client: *Client, result: anyerror!void) !void {
    try client.graphics_resume.complete(result);
    try resumeGraphics(client);
}

/// A graphics snapshot of a paused pane arrived and was applied. Its begin
/// marks the pause as resuming; its end, when the pane did not reach its
/// limit again in between, ends the pause. The row stays as resumed, with
/// its backoff, so a pane that pauses again soon neither notices again nor
/// asks sooner.
///
/// ```zig
/// try limit_reached.receiveGraphicsSnapshot(client, snapshot);
/// ```
pub fn receiveGraphicsSnapshot(client: *Client, snapshot: core.Snapshot) !void {
    const pauses = &client.model.graphics_pauses;
    const slot = pauses.find(snapshot.pane_id) orelse return;
    switch (snapshot.phase) {
        .begin => pauses.snapshot_begun[slot] = true,
        .end => {
            if (!pauses.snapshot_begun[slot]) {
                return;
            }

            pauses.snapshot_begun[slot] = false;
            pauses.setWaiting(slot, false);
            pauses.resumed_ns[slot] = pacing.clock.monotonic(client.io);
            client.model.pane_graphics_revision +%= 1;
            try scheduleResume(client);
        },
    }
}

/// A pane's graphics paused at a limit. Every reach counts; a notice naming
/// the pane shows only when its pause starts. Its own budget allows
/// `max_limit_resyncs` snapshots within `runtime_link.healthy_after_ns`,
/// then it waits (`wait`). It never spends the link's budget.
fn pauseGraphics(client: *Client, reach: core.LimitReach, pane_id: core.PaneId) !void {
    const recorded = countReach(client, reach);
    const pauses = &client.model.graphics_pauses;
    const now_ns = pacing.clock.monotonic(client.io);
    var found = pauses.find(pane_id);
    if (found) |slot| {
        if (pauses.resumed_ns[slot]) |resumed_ns| {
            // Paused again: soon after resuming it goes on quietly with its
            // backoff; after a healthy window it is a new pause.
            pauses.resumed_ns[slot] = null;
            client.model.pane_graphics_revision +%= 1;
            if (now_ns -| resumed_ns >= runtime_link.healthy_after_ns) {
                pauses.remove(slot);
                found = null;
            }
        }
    }

    if (found == null) {
        found = try startPause(
            client,
            pane_id,
            now_ns,
        );
        if (found != null) {
            showPause(
                client,
                recorded.slot,
                pane_id,
            );
        }
    }

    // A pane the client does not mirror only counts.
    const slot = found orelse return;
    pauses.snapshot_begun[slot] = false;
    if (pauses.waiting[slot]) {
        return;
    }

    if (now_ns -| pauses.since_ns[slot] >= runtime_link.healthy_after_ns) {
        pauses.resyncs[slot] = 0;
        pauses.since_ns[slot] = now_ns;
    }

    pauses.resyncs[slot] +|= 1;
    if (pauses.resyncs[slot] > max_limit_resyncs) {
        return wait(client, slot);
    }

    askGraphics(client, pane_id) catch |failed| try runtime_link.lose(client, failed);
}

/// Adds the row of a pane whose pause starts. A full table gives up the
/// row whose window started longest ago, and a waiting one asks its
/// snapshot now, so no pane stays paused without a resume on the way.
/// Returns null for a pane the client does not mirror.
fn startPause(client: *Client, pane_id: core.PaneId, now_ns: u64) !?usize {
    const model = &client.model;
    if (model.panes.findConst(pane_id) == null) {
        return null;
    }

    const pauses = &model.graphics_pauses;
    if (pauses.count == data.GraphicsPauses.capacity) {
        const evicted = pauses.oldest();
        const evicted_pane = pauses.pane_id[evicted];
        const waiting = pauses.waiting[evicted];
        pauses.remove(evicted);
        if (waiting) {
            askGraphics(client, evicted_pane) catch |failed| {
                try runtime_link.lose(client, failed);
                return null;
            };
        }
    }

    model.pane_graphics_revision +%= 1;
    return pauses.add(pane_id, now_ns);
}

/// A pane spent its window's budget: it waits until its window, doubled
/// for each window of this pause that already ended waiting, has passed.
fn wait(client: *Client, slot: usize) !void {
    const pauses = &client.model.graphics_pauses;
    pauses.due_ns[slot] = pauses.since_ns[slot] +| pauseWindowNs(pauses.backoff[slot]);
    pauses.backoff[slot] +|= 1;
    pauses.setWaiting(slot, true);
    try scheduleResume(client);
}

/// The window of a pause whose `backoff` windows already ended waiting.
fn pauseWindowNs(backoff: u8) u64 {
    const doublings: u6 = @intCast(@min(backoff, max_pause_doublings));
    const window_ns: u64 = runtime_link.healthy_after_ns;
    return window_ns << doublings;
}

/// Starts a new window for a waiting row and asks its snapshot.
fn resumeRow(client: *Client, slot: usize, now_ns: u64) !void {
    const pauses = &client.model.graphics_pauses;
    pauses.resyncs[slot] = 1;
    pauses.since_ns[slot] = now_ns;
    pauses.snapshot_begun[slot] = false;
    pauses.setWaiting(slot, false);
    try askGraphics(client, pauses.pane_id[slot]);
}

/// Arms the timer for the earliest waiting row, or lets it idle when none
/// waits.
fn scheduleResume(client: *Client) !void {
    const scheduler = &client.graphics_resume;
    switch (scheduler.update(client.io, client.model.graphics_pauses.nextDue())) {
        .idle, .retained => {},
        .schedule => client.to_workers.push(.{
            .timer = .{
                .kind = .graphics_resume,
                .scheduler = scheduler,
            },
        }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
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
    const recorded = countReach(client, reach);
    if (!recorded.show) {
        return false;
    }

    publish(
        client,
        recorded.slot,
        core.limit_reached.notice_title,
        .none,
    );
    return true;
}

/// Counts one reach in `model.limit_reaches` and reports it to the runtime
/// when its interval allows, so `telar diagnostics limits` lists every one.
fn countReach(client: *Client, reach: core.LimitReach) core.RecordedReach {
    const at: core.ReachTime = .{
        .awake_ms = std.Io.Timestamp.now(client.io, .awake).toMilliseconds(),
        .real_ms = std.Io.Timestamp.now(client.io, .real).toMilliseconds(),
    };
    const recorded = core.limit_reached.record(
        &client.model.limit_reaches,
        reach,
        at,
        1,
    );
    send(
        client,
        recorded.slot,
        at.awake_ms,
    );
    return recorded;
}

/// Shows that a pane's images paused, naming the pane; a click focuses it.
fn showPause(client: *Client, slot: usize, pane_id: core.PaneId) void {
    var storage: [core.max_notification_title_bytes + core.max_foreground_name_bytes]u8 = undefined;
    const title = pausedTitle(
        &client.model,
        pane_id,
        &storage,
    );
    publish(
        client,
        slot,
        title,
        .{
            .focus_pane = pane_id,
        },
    );
}

/// "Images paused in pane 2: vim": the pane's number and program as its
/// header shows them. The notice keeps what fits its title.
fn pausedTitle(model: *const data.ClientModel, pane_id: core.PaneId, storage: []u8) []const u8 {
    const pane = model.panes.findConst(pane_id) orelse return paused_title;
    const foreground = pane.foregroundName();
    const name = if (foreground.len != 0 and std.unicode.utf8ValidateSlice(foreground)) foreground else unnamed_pane;
    const tab = model.tabs.find(pane.location.tab_id) orelse return paused_title;
    const index = model.tabs.layout[tab].displayIndex(pane_id) orelse return paused_title;
    return std.fmt.bufPrint(
        storage,
        "Images paused in pane {d}: {s}",
        .{
            index,
            name,
        },
    ) catch paused_title;
}

/// Logs a recorded reach and shows it under `title`.
fn publish(client: *Client, slot: usize, title: []const u8, target: data.NotificationTarget) void {
    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    const reaches = &client.model.limit_reaches;
    const text = reaches.reachAt(slot).describe(&buffer, reaches.hits[slot]);
    log.warn("{s}: {s}", .{ title, text });
    notifications.publishNotificationNow(
        client,
        .{
            .level = .warning,
            .title = title,
            .message = text,
            .target = target,
            .duration_ns = notice_duration_ns,
        },
    ) catch |err| log.warn("limit notice not shown: {s}", .{@errorName(err)});
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

test "each pane that starts a pause gets its own notice naming it, and more reaches only count" {
    try client_tests.noticePausedPanes(recover);
}

test "a paused pane resumes from its timer or its focus without runtime traffic" {
    try client_tests.resumeWithoutTraffic(recover, finishResumeTick);
}

test "a pause ends when its snapshot applies, and a full table leaves no pane without a resume" {
    try client_tests.endGraphicsPauses(recover);
}

test "each window a pause ends waiting doubles the next wait up to sixteen minutes" {
    try std.testing.expectEqual(runtime_link.healthy_after_ns, pauseWindowNs(0));
    try std.testing.expectEqual(2 * runtime_link.healthy_after_ns, pauseWindowNs(1));
    try std.testing.expectEqual(4 * runtime_link.healthy_after_ns, pauseWindowNs(2));
    try std.testing.expectEqual(16 * std.time.ns_per_min, pauseWindowNs(max_pause_doublings));
    try std.testing.expectEqual(16 * std.time.ns_per_min, pauseWindowNs(std.math.maxInt(u8)));
    try client_tests.backOffPausedPanes(
        recover,
        resumeGraphics,
        receiveGraphicsSnapshot,
    );
}
