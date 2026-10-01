//! Limit reached, runtime side: a limit the runtime reached is counted in
//! `model.limit_reaches`, logged, and shown to every window at most once per
//! `limit_reached.show_interval_ms`; one a client reported is counted apart
//! in `model.client_limit_reaches`. `telar diagnostics limits` lists both.
//! The safety nets here keep a limit error from ending `Runtime.run`.
//!
//! Everything here runs on the runtime's event loop, the thread that owns
//! the model. A worker never calls it: it returns the reach in its
//! completion and the flow's `finish` reports it. See
//! `docs/flows/limit-reached.md`.
const std = @import("std");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const notifications = @import("notifications.zig");
const client_request = @import("client_request.zig");

const log = std.log.scoped(.limits);

/// Length of a notice's text frame; validation encodes it here first.
const notice_validation_bytes = 512;
/// How long a limit notice stays on screen.
const notice_duration_ms = 8_000;
/// `report_limit` messages one connection may send a second; an honest
/// client sends one a second per limit it keeps reaching.
const max_reports_per_second = 32;

/// Counts one reach of a runtime limit, and at most once per interval logs
/// it and shows it to every window. Never fails and allocates nothing, so
/// it can sit where the limit is enforced. Call it on the event loop only.
///
/// ```zig
/// limit_reached.report(model, .{
///     .limit = core.Limit.declare("session_checkpoint.snapshot_bytes", "bytes", snapshot_bytes),
///     .requested = needed,
/// });
/// ```
pub fn report(model: *RuntimeModel, reach: core.LimitReach) void {
    _ = notice(model, reach);
}

/// Counts what a client reported, apart from the runtime's own limits. A
/// window already showed and logged its notice, so the runtime only counts.
/// A command-line connection (`telar hook`, `telar history import`) has no
/// window, so the runtime shows its notice once per interval of its row,
/// the way `telar notification show` could; it still never touches a
/// runtime row. A connection past `max_reports_per_second` is refused and
/// counted.
///
/// ```zig
/// limit_reached.receive(model, session, report);
/// ```
pub fn receive(model: *RuntimeModel, session: *Session, reported: core.ReportLimit) void {
    const at = now(model);
    if (!admit(model, session, at)) {
        return;
    }

    const reaches = &model.client_limit_reaches;
    const recorded = core.limit_reached.record(reaches, reported.reach, at, reported.hits);
    if (session.role != .control or !recorded.show) {
        return;
    }

    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    show(model, reaches.reachAt(recorded.slot).describe(&buffer, reaches.hits[recorded.slot]));
}

/// Whether one more report from this connection fits its second; one that
/// does not is counted as refused.
fn admit(model: *RuntimeModel, session: *Session, at: core.ReachTime) bool {
    if (at.awake_ms - session.limit_report_window_ms >= std.time.ms_per_s) {
        session.limit_report_window_ms = at.awake_ms;
        session.limit_reports = 0;
    }

    if (session.limit_reports >= max_reports_per_second) {
        model.refused_limit_reports +|= 1;
        return false;
    }

    session.limit_reports += 1;
    return true;
}

/// Answers `telar diagnostics limits` with both tables, encoded from them
/// when the reply is sent.
///
/// ```zig
/// try limit_reached.list(session, query);
/// ```
pub fn list(session: *Session, query: core.QueryLimits) !void {
    try session.delivery.responses.push(.{ .limit_list = query.request_id });
}

/// The safety net of `Runtime.update`: a limit error from one event is
/// reported with its route and the event is skipped. A host error is
/// logged as an error and returns, like any other error.
///
/// ```zig
/// dispatch(event) catch |err| try limit_reached.absorb(model, @tagName(event), err);
/// ```
pub fn absorb(model: *RuntimeModel, route: []const u8, err: anyerror) anyerror!void {
    if (!core.limit_reached.isLimitError(err)) {
        logUncaught(route, err);
        return err;
    }

    if (notice(model, core.limit_reached.unnamed(err, route))) {
        log.warn("{s} stopped at a limit: {s}", .{ route, @errorName(err) });
    }
}

/// The safety net of one client request: a limit error answers the request
/// with `resource_limit` and keeps the connection. The limit is recorded
/// within the connection's report budget, so a client sending requests
/// that stop at a limit cannot flood the runtime's table or its notices. A
/// full response queue is the slow-client policy, not a limit, so it and
/// every other error return and the connection is dropped as before.
///
/// ```zig
/// client_request.receive(model, session, message) catch |err| try limit_reached.refuse(model, session, message, err);
/// ```
pub fn refuse(model: *RuntimeModel, session: *Session, message: core.ClientMessage, err: anyerror) anyerror!void {
    const route = @tagName(message);
    if (err == error.ResponseQueueFull or !core.limit_reached.isLimitError(err)) {
        logUncaught(route, err);
        return err;
    }

    if (admit(model, session, now(model)) and notice(model, core.limit_reached.unnamed(err, route))) {
        log.warn("request {s} stopped at a limit: {s}", .{ route, @errorName(err) });
    }

    const request_id = requestId(message) orelse return;
    try client_request.fail(session, request_id, .resource_limit, @errorName(err));
}

/// Records one reach and shows it when its interval allows; returns
/// whether it showed, so a caller logs its own detail only then.
fn notice(model: *RuntimeModel, reach: core.LimitReach) bool {
    const reaches = &model.limit_reaches;
    const recorded = core.limit_reached.record(reaches, reach, now(model), 1);
    if (!recorded.show) {
        return false;
    }

    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    const text = reaches.reachAt(recorded.slot).describe(&buffer, reaches.hits[recorded.slot]);
    log.warn("{s}", .{text});
    show(model, text);
    return true;
}

/// A host error is not hidden: it is logged with its route before it
/// takes its old path.
fn logUncaught(route: []const u8, err: anyerror) void {
    if (core.limit_reached.isSystemError(err)) {
        log.err("{s} failed on the host: {s}", .{ route, @errorName(err) });
    }
}

fn requestId(message: core.ClientMessage) ?core.RequestId {
    switch (message) {
        inline else => |value| {
            const Value = @TypeOf(value);
            if (comptime @typeInfo(Value) == .@"struct" and @hasField(Value, "request_id")) {
                if (value.request_id != .none) {
                    return value.request_id;
                }
            }
        },
    }

    return null;
}

fn show(model: *RuntimeModel, text: []const u8) void {
    const notification: core.Notification = .{
        .level = .warning,
        .duration_ms = notice_duration_ms,
        .title = core.limit_reached.notice_title,
        .message = text,
    };

    var validation_buffer: [notice_validation_bytes]u8 = undefined;
    _ = core.encodeNotification(&validation_buffer, notification) catch return;
    _ = notifications.publish(model, notification);
}

fn now(model: *const RuntimeModel) core.ReachTime {
    return .{
        .awake_ms = std.Io.Timestamp.now(model.io, .awake).toMilliseconds(),
        .real_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
    };
}
