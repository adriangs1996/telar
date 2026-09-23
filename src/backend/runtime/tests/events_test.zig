//! Completion contracts through the real runtime update entrypoint.
const std = @import("std");
const core = @import("telar-core");
const RequestFixture = @import("RequestFixture.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const Entry = @import("../../history/Entry.zig");
const runtime_event = @import("../event.zig");

test "runtime update ignores retired client and pane generations" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    var stale_client = fixture.session.key;
    stale_client.generation += 1;
    var stale_pane = pane.key();
    stale_pane.generation += 1;
    const actors = pane.actor_count;
    const completions = [_]runtime_event.Event{
        .{ .client_message = .{ .client = stale_client, .result = error.ConnectionClosed } },
        .{ .client_sent = .{ .client = stale_client, .result = error.BrokenPipe } },
        .{ .pane_input_written = .{ .pane = stale_pane, .started_ns = 0, .result = error.BrokenPipe } },
        .{ .pane_response_written = .{ .pane = stale_pane, .result = error.BrokenPipe } },
        .{ .pane_output = .{ .pane = stale_pane, .result = error.EndOfStream } },
        .{ .pane_exit = .{ .pane = stale_pane, .result = .{ .exited = 0 } } },
    };
    for (completions) |completion| {
        try std.testing.expect(!try fixture.runtime.update(completion));
    }
    try std.testing.expectEqual(@as(u64, 2), fixture.runtime.model.metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 4), fixture.runtime.model.metrics.stale_pane_events);
    try std.testing.expectEqual(actors, pane.actor_count);
    try std.testing.expect(pane.exit == null);
    try std.testing.expect(fixture.session.send_pending);
    try std.testing.expect(!fixture.session.closing);
}

test "runtime update retains a closing client until its final socket borrow completes" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const key = fixture.session.key;
    fixture.session.read_pending = true;
    try std.testing.expect(!try fixture.runtime.update(.{ .client_message = .{
        .client = key,
        .result = error.EndOfStream,
    } }));
    try std.testing.expect(!fixture.session.read_pending);
    try std.testing.expect(fixture.session.send_pending);
    try std.testing.expect(fixture.session.closing);
    try std.testing.expect(fixture.runtime.model.clients.resolve(key) != null);

    try std.testing.expect(!try fixture.runtime.update(.{ .client_sent = .{
        .client = key,
        .result = error.BrokenPipe,
    } }));
    try std.testing.expect(fixture.runtime.model.clients.resolve(key) == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.runtime.model.clients.count);
}

test "runtime update releases a failed PTY input borrow and discards its queued suffix" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const actors = pane.actor_count;
    try std.testing.expect(pane.input_queue.push("first"));
    try std.testing.expectEqualStrings("first", pane.beginPtyInputWrite().?);
    try std.testing.expect(pane.input_queue.push("suffix"));
    try std.testing.expectEqual(actors + 1, pane.actor_count);

    try std.testing.expect(!try fixture.runtime.update(.{ .pane_input_written = .{
        .pane = pane.key(),
        .started_ns = core.now(std.testing.io),
        .result = error.BrokenPipe,
    } }));
    try std.testing.expectEqual(actors, pane.actor_count);
    try std.testing.expect(!pane.input_write_pending);
    try std.testing.expectEqual(@as(usize, 0), pane.input_write_len);
    try std.testing.expect(pane.input_queue.nextChunk() == null);
}

test "runtime update decodes a first stop request and records its control role" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.session.role = .undecided;
    fixture.session.read_pending = true;
    var buffer: [16]u8 = undefined;
    const payload = try core.encodeRuntimeStop(&buffer);
    try std.testing.expect(!try fixture.runtime.update(.{ .client_message = .{
        .client = fixture.session.key,
        .result = @constCast(payload),
    } }));
    try std.testing.expectEqual(.control, fixture.session.role);
    try std.testing.expect(!fixture.session.read_pending);
    try std.testing.expect(fixture.runtime.model.shutdown.isRequested());
    try std.testing.expectEqualDeep(fixture.session.key, fixture.runtime.model.shutdown.initiator.?);
}

test "runtime update transfers history ownership only to the matching available client queue" {
    const Situation = enum { accepted, stale, full };
    for ([_]Situation{ .accepted, .stale, .full }) |situation| {
        var fixture: RequestFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        if (situation == .full) {
            try fixture.fillResponses();
        }
        const queued_before = fixture.session.delivery.responses.len;
        var origin_key = fixture.session.key;
        if (situation == .stale) {
            origin_key.generation += 1;
        }
        const result = try std.testing.allocator.create(QueryResult);
        result.* = .{
            .request_id = @enumFromInt(77),
            .origin = .{ .client = origin_key, .close_after_reply = true },
            .entries = try std.testing.allocator.alloc(Entry, 0),
            .gpa = std.testing.allocator,
        };
        try std.testing.expect(!try fixture.runtime.update(.{ .history_response = .{ .query_result = result } }));
        if (situation == .accepted) {
            try std.testing.expectEqual(queued_before + 1, fixture.session.delivery.responses.len);
            try std.testing.expect(fixture.response().?.history_result == result);
        } else {
            try std.testing.expectEqual(queued_before, fixture.session.delivery.responses.len);
        }
        try std.testing.expectEqual(situation != .stale, fixture.session.delivery.close_after_reply);
        // The testing allocator verifies disposal for stale and full queues;
        // the accepted queue releases its transferred result during teardown.
    }
}

test "runtime update ignores a failed history receive without touching client delivery" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try std.testing.expect(!try fixture.runtime.update(.{ .history_response = error.ResponseQueueClosed }));
    try std.testing.expect(fixture.response() == null);
    try std.testing.expect(!fixture.session.delivery.close_after_reply);
    try std.testing.expect(fixture.session.active());
}

test "runtime update correlates history failures without consuming another generation" {
    for ([_]bool{ false, true }) |stale| {
        var fixture: RequestFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var origin_key = fixture.session.key;
        if (stale) {
            origin_key.generation += 1;
        }
        try std.testing.expect(!try fixture.runtime.update(.{ .history_response = .{ .failed = .{
            .request_id = @enumFromInt(77),
            .origin = .{ .client = origin_key, .close_after_reply = true },
            .message = "history unavailable",
        } } }));
        if (stale) {
            try std.testing.expect(fixture.response() == null);
        } else {
            const failure = fixture.response().?.request_failed;
            try std.testing.expectEqual(@as(core.RequestId, @enumFromInt(77)), failure.request_id);
            try std.testing.expectEqual(core.FailureCode.internal, failure.code);
        }
        try std.testing.expectEqual(!stale, fixture.session.delivery.close_after_reply);
    }
}
