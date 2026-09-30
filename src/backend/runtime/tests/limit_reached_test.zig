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
const observer_support = @import("../../history/observer_support.zig");
const pane_observation = @import("../pane_observation.zig");
const cmdcapture = @import("cmdcapture");
const Clock = cmdcapture.Clock;

const checkpoint_limit: core.LimitReach = .{
    .limit = core.Limit.declare("session_checkpoint.snapshot_bytes", "bytes", 1024),
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

    model.limit_reaches.shown_ms[slot] = model.limit_reaches.shown_ms[slot].? - core.limit_reached.show_interval_ms;
    limit_reached.report(model, checkpoint_limit);
    try std.testing.expectEqual(@as(usize, 2), countNotices(fixture.session));
    try std.testing.expectEqual(@as(u64, 3), model.limit_reaches.hits[slot]);
}

test "a client's reaches are counted apart and listed with the runtime's" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    limit_reached.report(model, checkpoint_limit);
    fixture.clearResponses();

    try fixture.send(.{ .report_limit = .{
        .reach = .{
            .limit = core.Limit.declare("bars.max_bar_actions", "click actions", 4),
            .requested = 5,
        },
        .hits = 3,
    } });
    try std.testing.expect(fixture.response() == null);
    try std.testing.expect(model.limit_reaches.find("bars.max_bar_actions") == null);

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
        .runtime_limits = &model.limit_reaches,
        .client_limits = &model.client_limit_reaches,
        .refused_limit_reports = model.refused_limit_reports,
    }, pending);
    const decoded = try core.decodeServer(payload);
    try std.testing.expectEqual(@as(u16, 2), decoded.limit_list.entry_count);

    var entries = decoded.limit_list.entries();
    const runtime_entry = (try entries.next()).?;
    try std.testing.expectEqual(core.LimitOrigin.runtime, runtime_entry.origin);
    const client_entry = (try entries.next()).?;
    try std.testing.expectEqualStrings("bars.max_bar_actions", client_entry.reach.limit.name);
    try std.testing.expectEqual(core.LimitOrigin.client, client_entry.origin);
    try std.testing.expectEqual(@as(u64, 3), client_entry.hits);
    try std.testing.expectEqual(@as(?u64, 5), client_entry.reach.requested);
}

test "a client reporting a runtime limit's name neither silences nor evicts it" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    try fixture.send(.{ .report_limit = .{
        .reach = checkpoint_limit,
        .hits = 1,
    } });

    var name_buffer: [32]u8 = undefined;
    for (0..core.LimitReaches.capacity + 1) |number| {
        // A new second for every report keeps this client under its rate.
        fixture.session.limit_report_window_ms = 0;
        try fixture.send(.{ .report_limit = .{
            .reach = .{
                .limit = .{
                    .name = try std.fmt.bufPrint(&name_buffer, "invented.{d}", .{number}),
                    .value = 1,
                },
            },
            .hits = 1,
        } });
    }

    limit_reached.report(model, checkpoint_limit);
    try std.testing.expectEqual(@as(usize, 1), countNotices(fixture.session));
    try std.testing.expectEqual(@as(u64, 1), model.limit_reaches.hits[model.limit_reaches.find("session_checkpoint.snapshot_bytes").?]);
    try std.testing.expect(model.client_limit_reaches.evicted >= 2);
    try std.testing.expectEqual(@as(u64, 0), model.limit_reaches.evicted);
}

test "a command-line report shows its notice once per interval and keeps the runtime's rows" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    const hook = try fixture.addClient();
    hook.role = .control;
    const reach: core.LimitReach = .{
        .limit = core.Limit.declare("hooks.max_input_bytes", "bytes", 16),
        .requested = 17,
    };

    try fixture.sendTo(hook, .{ .report_limit = .{
        .reach = reach,
        .hits = 1,
    } });
    try fixture.sendTo(hook, .{ .report_limit = .{
        .reach = reach,
        .hits = 1,
    } });

    try std.testing.expectEqual(@as(usize, 1), countNotices(fixture.session));
    try std.testing.expectEqual(@as(usize, 0), countNotices(hook));
    try std.testing.expectEqualStrings("hooks.max_input_bytes: 17 bytes; limit 16", fixture.response().?.notification.view().message);
    try std.testing.expect(model.limit_reaches.find("hooks.max_input_bytes") == null);

    const slot = model.client_limit_reaches.find("hooks.max_input_bytes").?;
    try std.testing.expectEqual(@as(u64, 2), model.client_limit_reaches.hits[slot]);
}

test "a history batch drop and a refused command report their limits and keep the pane observed" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    const pane = try fixture.openPane();
    const burst = try std.testing.allocator.alloc(u8, observer_support.batch_bytes + 1);
    defer std.testing.allocator.free(burst);
    @memset(burst, 'x');

    const clock: Clock = .{
        .real_ms = 1,
        .awake_ns = 1,
    };
    pane.queueHistoryOutput(.{
        .bytes = burst,
        .shell_foreground = true,
        .clock = clock,
    });
    pane.queueHistoryOutput(.{
        .bytes = "kept",
        .shell_foreground = true,
        .clock = clock,
    });
    const borrow = pane.beginHistoryObservation().?;

    try pane_observation.finish(model, .{
        .pane = pane.key(),
        .stats = .{
            .refused = 1,
        },
        .process_probe = .{
            .cache = borrow.process_cache,
        },
    });

    const batch = model.limit_reaches.find("history.observer_batch_bytes").?;
    try std.testing.expectEqual(@as(?u64, observer_support.batch_bytes + 1), model.limit_reaches.requested[batch]);
    try std.testing.expect(model.limit_reaches.find("history.request_queue") != null);
    try std.testing.expect(model.panes.find(pane.id) != null);
    try std.testing.expect(pane.history_observer.takeDrop() == null);
}

test "a connection sending too many reports a second is refused and counted" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    for (0..40) |_| {
        try fixture.send(.{ .report_limit = .{
            .reach = checkpoint_limit,
            .hits = 1,
        } });
    }

    const slot = model.client_limit_reaches.find("session_checkpoint.snapshot_bytes").?;
    try std.testing.expectEqual(@as(u64, 32), model.client_limit_reaches.hits[slot]);
    try std.testing.expectEqual(@as(u64, 8), model.refused_limit_reports);
}

test "a request stopped by a limit is refused and its connection stays" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    const message: core.ClientMessage = .{ .query_limits = .{ .request_id = @enumFromInt(9) } };
    try limit_reached.refuse(model, fixture.session, message, error.TooManyTabs);

    const failure = findFailure(fixture.session).?;
    try std.testing.expectEqual(core.FailureCode.resource_limit, failure.code);
    try std.testing.expectEqual(@as(core.RequestId, @enumFromInt(9)), failure.request_id);
    const slot = model.limit_reaches.find("TooManyTabs").?;
    try std.testing.expectEqualStrings("query_limits", model.limit_reaches.reachAt(slot).route);

    try std.testing.expectError(error.ResponseQueueFull, limit_reached.refuse(model, fixture.session, message, error.ResponseQueueFull));
    try std.testing.expectError(error.Unexpected, limit_reached.refuse(model, fixture.session, message, error.Unexpected));
}

test "the update safety net skips an event at a limit and returns every other error" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    try limit_reached.absorb(model, "agent_tick", error.BufferTooSmall);
    const slot = model.limit_reaches.find("BufferTooSmall").?;
    try std.testing.expectEqual(@as(u64, 1), model.limit_reaches.hits[slot]);
    try std.testing.expectEqualStrings("agent_tick", model.limit_reaches.reachAt(slot).route);

    // A host error is logged as an error before it returns, which a test
    // counts as a failure; core's tests prove its classification.
    try std.testing.expectError(error.InvalidCheckpoint, limit_reached.absorb(model, "agent_tick", error.InvalidCheckpoint));
    try std.testing.expect(model.limit_reaches.find("InvalidCheckpoint") == null);
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

test "Runtime.update skips an event that stops at a limit and keeps running" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const runtime = fixture.runtime;
    const stopped = try runtime.update(.{ .pane_search = .{
        .client = fixture.session.key,
        .request_id = @enumFromInt(3),
        .result = error.QueueFull,
    } });
    try std.testing.expect(!stopped);

    const reaches = &runtime.model.limit_reaches;
    const slot = reaches.find("QueueFull").?;
    try std.testing.expectEqualStrings("pane_search", reaches.reachAt(slot).route);
    try std.testing.expect(runtime.model.clients.resolve(fixture.session.key) != null);

    // The next event runs as usual.
    try fixture.send(.{ .query_limits = .{ .request_id = @enumFromInt(4) } });
    try std.testing.expect(findLimitList(fixture.session));
}

fn findLimitList(session: *Session) bool {
    const queue = &session.delivery.responses;
    for (0..queue.len) |offset| {
        const index = (@as(usize, queue.head) + offset) % queue.items.len;
        if (queue.items[index] == .limit_list) {
            return true;
        }
    }

    return false;
}
