//! Limit reached, runtime side: a limit the runtime reached is counted in
//! `model.limit_reaches`, logged, and shown to every window at most once per
//! `LimitReaches.show_interval_ms`; one a client reported is counted.
//! `telar diagnostics limits` lists the registry. The safety nets here keep
//! a capacity error from ending `Runtime.run`. See
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

/// Counts one reach of a runtime limit, and at most once per interval logs
/// it and shows it to every window. Never fails and allocates nothing, so
/// it can sit where the limit is enforced.
///
/// ```zig
/// limit_reached.report(model, .{
///     .limit = .{ .name = "session_checkpoint.snapshot_bytes", .noun = "bytes", .value = snapshot_bytes },
///     .requested = needed,
/// });
/// ```
pub fn report(model: *RuntimeModel, reach: core.LimitReach) void {
    const recorded = model.limit_reaches.record(reach, .runtime, nowMs(model), 1);
    if (!recorded.show) {
        return;
    }

    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    const text = model.limit_reaches.reachAt(recorded.slot).describe(&buffer, model.limit_reaches.hits[recorded.slot]);
    log.warn("{s}", .{text});
    show(model, text);
}

/// Counts what a client reported. The client already showed and logged
/// its own notice, so the runtime only counts: a client inventing names
/// cannot grow the runtime's log.
///
/// ```zig
/// limit_reached.receive(model, report);
/// ```
pub fn receive(model: *RuntimeModel, reported: core.ReportLimit) void {
    _ = model.limit_reaches.record(reported.reach, .client, nowMs(model), reported.hits);
}

/// Answers `telar diagnostics limits` with the whole registry, encoded
/// from the table when the reply is sent.
///
/// ```zig
/// try limit_reached.list(session, query);
/// ```
pub fn list(session: *Session, query: core.QueryLimits) !void {
    try session.delivery.responses.push(.{ .limit_list = query.request_id });
}

/// The safety net of `Runtime.update`: a capacity error from one event is
/// logged with its route, reported, and the event is skipped; any other
/// error returns to the caller unchanged.
///
/// ```zig
/// dispatch(event) catch |err| try limit_reached.absorb(model, @tagName(event), err);
/// ```
pub fn absorb(model: *RuntimeModel, route: []const u8, err: anyerror) anyerror!void {
    if (!core.limit_reached.isCapacityError(err)) {
        return err;
    }

    log.warn("{s} stopped at a limit: {s}", .{ route, @errorName(err) });
    report(model, core.limit_reached.unnamed(err));
}

/// The safety net of one client request: a capacity error answers the
/// request with `resource_limit` and keeps the connection. A full response
/// queue is the slow-client policy, not a limit, so it and every other
/// error return and the connection is dropped as before.
///
/// ```zig
/// client_request.receive(model, session, message) catch |err| try limit_reached.refuse(model, session, message, err);
/// ```
pub fn refuse(model: *RuntimeModel, session: *Session, message: core.ClientMessage, err: anyerror) anyerror!void {
    if (err == error.ResponseQueueFull or !core.limit_reached.isCapacityError(err)) {
        return err;
    }

    log.warn("request {s} stopped at a limit: {s}", .{ @tagName(message), @errorName(err) });
    report(model, core.limit_reached.unnamed(err));

    const request_id = requestId(message) orelse return;
    try client_request.fail(session, request_id, .resource_limit, @errorName(err));
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

fn nowMs(model: *const RuntimeModel) i64 {
    return std.Io.Timestamp.now(model.io, .real).toMilliseconds();
}
