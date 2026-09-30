//! Limit reached, client side: a limit this client or its window reached is
//! counted in `model.limit_reaches`, shown in this window at most once per
//! `LimitReaches.show_interval_ms`, logged, and folded into one
//! `report_limit` a second so `telar diagnostics limits` lists it. See
//! `docs/flows/limit-reached.md`.
const std = @import("std");
const core = @import("telar-core");
const Client = @import("../execution/Client.zig");
const notifications = @import("notifications.zig");

const log = std.log.scoped(.limits);

/// How long a limit notice stays on screen.
const notice_duration_ns = 8 * std.time.ns_per_s;
/// Outbox slots a report leaves free, so input and requests never wait
/// behind one; a report that finds fewer waits for the next reach.
const outbox_reserve = 8;

/// Counts one reach of a limit; shows it, logs it and reports it to the
/// runtime when its interval allows. Never fails and allocates nothing, so
/// it can sit where the limit is enforced.
///
/// ```zig
/// limit_reached.report(client, .{
///     .limit = .{ .name = "bars.max_bar_actions", .noun = "click actions", .value = model.max_bar_actions },
///     .requested = actions,
/// });
/// ```
pub fn report(client: *Client, reach: core.LimitReach) void {
    _ = notice(client, reach);
}

/// Records one reach and shows it when its interval allows; returns
/// whether it showed, so a caller logs its own detail only then.
fn notice(client: *Client, reach: core.LimitReach) bool {
    const now_ms = std.Io.Timestamp.now(client.io, .real).toMilliseconds();
    const reaches = &client.model.limit_reaches;
    const recorded = reaches.record(reach, .client, now_ms, 1);
    send(client, recorded.slot, now_ms);

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
            .title = core.limit_reached.notice_title,
            .message = text,
            .duration_ns = notice_duration_ns,
        },
    ) catch |err| log.warn("limit notice not shown: {s}", .{@errorName(err)});

    return true;
}

/// The safety net of a presentation adapter: a capacity error is reported
/// under `limit`, or under its own name when null, and the caller keeps
/// what it has; any other error returns. The route and the error are logged
/// with the notice, so a limit reached every frame logs once a minute.
///
/// ```zig
/// gui.draw(viewport) catch |err| try limit_reached.absorb(gui.app, "window draw", err, null);
/// ```
pub fn absorb(client: *Client, route: []const u8, err: anyerror, limit: ?core.Limit) anyerror!void {
    if (!core.limit_reached.isCapacityError(err)) {
        return err;
    }

    const reach: core.LimitReach = if (limit) |named| .{ .limit = named } else core.limit_reached.unnamed(err);
    if (notice(client, reach)) {
        log.warn("{s} stopped at a limit: {s}", .{ route, @errorName(err) });
    }
}

fn send(client: *Client, slot: usize, now_ms: i64) void {
    if (client.model.to_runtime.availableCapacity() <= outbox_reserve) {
        return;
    }

    const reaches = &client.model.limit_reaches;
    const hits = reaches.takeReport(slot, now_ms) orelse return;
    const reported: core.ReportLimit = .{
        .reach = reaches.reachAt(slot),
        .hits = hits,
    };

    client.model.to_runtime.pushEncoded(core.encodeReportLimit, reported) catch {
        reaches.restoreReport(slot, hits);
    };
}
