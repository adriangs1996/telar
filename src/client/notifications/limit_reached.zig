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

const log = std.log.scoped(.limits);

/// How long a limit notice stays on screen.
const notice_duration_ns = 8 * std.time.ns_per_s;
/// Outbox slots a report leaves free, so input and requests never wait
/// behind one: a report goes only while more than this many are free.
const outbox_reserve = 8;

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

/// Records one reach and shows it when its interval allows; returns
/// whether it showed, so a caller logs its own detail only then.
fn notice(client: *Client, reach: core.LimitReach) bool {
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
            .title = core.limit_reached.notice_title,
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
