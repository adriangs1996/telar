const std = @import("std");
const core = @import("telar-core");
const RequestFixture = @import("RequestFixture.zig");
const limit_reached = @import("../limit_reached.zig");
const encoder = @import("../delivery/encoder.zig");
const PendingFailure = @import("../delivery/PendingFailure.zig");
const Session = @import("../client/Session.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");

const checkpoint_limit: core.LimitReach = .{
    .limit = .{
        .name = "session_checkpoint.snapshot_bytes",
        .noun = "bytes",
        .value = 1024,
    },
    .requested = 4096,
};

test "a runtime limit notifies the windows once per interval and counts every reach" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    limit_reached.report(model, checkpoint_limit);
    limit_reached.report(model, checkpoint_limit);

    const slot = model.limit_reaches.find("session_checkpoint.snapshot_bytes").?;
    try std.testing.expectEqual(@as(u64, 2), model.limit_reaches.hits[slot]);
    try std.testing.expectEqual(@as(usize, 1), countNotices(fixture.session));

    const notice = fixture.response().?.notification.view();
    try std.testing.expectEqualStrings(core.limit_reached.notice_title, notice.title);
    try std.testing.expectEqualStrings("session_checkpoint.snapshot_bytes: 4096 bytes; limit 1024", notice.message);
    try std.testing.expectEqual(core.NotificationLevel.warning, notice.level);

    model.limit_reaches.shown_ms[slot] = model.limit_reaches.shown_ms[slot].? - core.LimitReaches.show_interval_ms;
    limit_reached.report(model, checkpoint_limit);
    try std.testing.expectEqual(@as(usize, 2), countNotices(fixture.session));
    try std.testing.expectEqual(@as(u64, 3), model.limit_reaches.hits[slot]);
}

test "a client's reaches are counted and listed with the runtime's" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    limit_reached.report(model, checkpoint_limit);
    fixture.clearResponses();

    try fixture.send(.{ .report_limit = .{
        .reach = .{
            .limit = .{
                .name = "bars.max_bar_actions",
                .noun = "click actions",
                .value = 4,
            },
            .requested = 5,
        },
        .hits = 3,
    } });
    try std.testing.expect(fixture.response() == null);

    try fixture.send(.{ .query_limits = .{ .request_id = @enumFromInt(7) } });
    const pending = fixture.response().?;
    try std.testing.expectEqual(@as(core.RequestId, @enumFromInt(7)), pending.limit_list);

    var buffer: [4096]u8 = undefined;
    var history_result: ?*QueryResult = null;
    var history_output: ?*OutputResult = null;
    var history_stats: ?*StatsResult = null;
    const payload = try encoder.encodeResponse(.{
        .buffer = &buffer,
        .panes = &model.panes,
        .workspaces = &model.workspaces,
        .history_result = &history_result,
        .history_output = &history_output,
        .history_stats = &history_stats,
        .limit_reaches = &model.limit_reaches,
    }, pending);
    const decoded = try core.decodeServer(payload);
    try std.testing.expectEqual(@as(u8, 2), decoded.limit_list.entry_count);

    var entries = decoded.limit_list.entries();
    const runtime_entry = (try entries.next()).?;
    try std.testing.expectEqual(core.LimitOrigin.runtime, runtime_entry.origin);
    const client_entry = (try entries.next()).?;
    try std.testing.expectEqualStrings("bars.max_bar_actions", client_entry.reach.limit.name);
    try std.testing.expectEqual(core.LimitOrigin.client, client_entry.origin);
    try std.testing.expectEqual(@as(u64, 3), client_entry.hits);
    try std.testing.expectEqual(@as(?u64, 5), client_entry.reach.requested);
}

test "a request stopped by a limit is refused and its connection stays" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    const message: core.ClientMessage = .{ .query_limits = .{ .request_id = @enumFromInt(9) } };
    try limit_reached.refuse(model, fixture.session, message, error.TooManyThings);

    const failure = findFailure(fixture.session).?;
    try std.testing.expectEqual(core.FailureCode.resource_limit, failure.code);
    try std.testing.expectEqual(@as(core.RequestId, @enumFromInt(9)), failure.request_id);
    try std.testing.expect(model.limit_reaches.find("TooManyThings") != null);

    try std.testing.expectError(error.ResponseQueueFull, limit_reached.refuse(model, fixture.session, message, error.ResponseQueueFull));
    try std.testing.expectError(error.Unexpected, limit_reached.refuse(model, fixture.session, message, error.Unexpected));
}

test "the update safety net skips an event at a limit and returns every other error" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    try limit_reached.absorb(model, "agent_tick", error.BufferTooSmall);
    try std.testing.expectEqual(@as(u64, 1), model.limit_reaches.hits[model.limit_reaches.find("BufferTooSmall").?]);
    try std.testing.expectError(error.InvalidCheckpoint, limit_reached.absorb(model, "agent_tick", error.InvalidCheckpoint));
}

fn countNotices(session: *Session) usize {
    const queue = &session.delivery.responses;
    var count: usize = 0;
    for (0..queue.len) |offset| {
        const index = (@as(usize, queue.head) + offset) % queue.items.len;
        if (queue.items[index] == .notification) {
            count += 1;
        }
    }

    return count;
}

fn findFailure(session: *Session) ?PendingFailure {
    const queue = &session.delivery.responses;
    for (0..queue.len) |offset| {
        const index = (@as(usize, queue.head) + offset) % queue.items.len;
        if (queue.items[index] == .request_failed) {
            return queue.items[index].request_failed;
        }
    }

    return null;
}
