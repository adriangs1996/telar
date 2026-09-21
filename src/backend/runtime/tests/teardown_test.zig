//! Cancellation owns completed results until they are released or retained by the model.
const std = @import("std");
const core = @import("telar-core");
const Loop = @import("../Loop.zig");
const history = @import("../../history/model.zig");
const QueryOrigin = @import("../../history/QueryOrigin.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const Entry = @import("../../history/Entry.zig");
const StatsTop = @import("../../history/StatsTop.zig");
const PluginResult = @import("../../plugins/Result.zig");
const Half = @import("../../proxy/capture/Half.zig");
const Quota = @import("../../proxy/capture/Quota.zig");
const ReviewJob = @import("../../change_review/Job.zig");
const ReviewResult = @import("../../change_review/Result.zig");
const RequestFixture = @import("RequestFixture.zig");
const EventFixture = @import("EventFixture.zig");
const pane_search = @import("../application/pane_search.zig");

fn finishHistory(result: history.Response) anyerror!history.Response {
    return result;
}

fn finishPlugin(result: *PluginResult) anyerror!*PluginResult {
    return result;
}

fn finishCapture(result: *Half) anyerror!*Half {
    return result;
}

fn finishAccept(result: core.SocketChannel) anyerror!core.SocketChannel {
    return result;
}

fn pluginResult(gpa: std.mem.Allocator) !*PluginResult {
    const result = try gpa.create(PluginResult);
    errdefer gpa.destroy(result);
    result.* = .{
        .gpa = gpa,
        .package_index = 0,
        .plugin_id = 1,
        .digest = @splat(0),
        .generation = 1,
        .event_id = 1,
        .pane = @enumFromInt(1),
        .pane_generation = 1,
        .storage = try gpa.dupe(u8, "owned effect"),
        .batch = .{},
    };
    return result;
}

test "loop cancellation releases every transferred result already queued by completed actors" {
    const loop = try std.testing.allocator.create(Loop);
    defer std.testing.allocator.destroy(loop);
    loop.init(std.testing.io, null);
    defer loop.cancel();
    var heap: core.Heap = .init(std.testing.allocator);
    const gpa = heap.allocator();
    const origin: QueryOrigin = .{ .client = .{ .id = 1, .generation = 1 }, .close_after_reply = false };

    const query = try gpa.create(QueryResult);
    query.* = .{ .request_id = @enumFromInt(1), .origin = origin, .gpa = gpa, .entries = try gpa.alloc(Entry, 0) };
    try loop.select.concurrent(.history_response, finishHistory, .{history.Response{ .query_result = query }});
    const output = try gpa.create(OutputResult);
    output.* = .{ .request_id = @enumFromInt(2), .origin = origin, .gpa = gpa, .id = 1, .truncated = false, .observed_bytes = 7, .content = try gpa.dupe(u8, "history") };
    try loop.select.concurrent(.history_response, finishHistory, .{history.Response{ .output_result = output }});
    const stats = try gpa.create(StatsResult);
    stats.* = .{ .request_id = @enumFromInt(3), .origin = origin, .gpa = gpa, .total = 1, .unique = 1, .top = try gpa.alloc(StatsTop, 1) };
    stats.top[0] = .{ .count = 1, .command = try gpa.dupe(u8, "pwd") };
    try loop.select.concurrent(.history_response, finishHistory, .{history.Response{ .stats_result = stats }});
    try loop.select.concurrent(.plugin_effects, finishPlugin, .{try pluginResult(gpa)});

    var quota: Quota = .init(16);
    const capture = try gpa.create(Half);
    capture.* = .{
        .gpa = gpa,
        .reservation = quota.reserve(16).?,
        .pane = .{ .id = @enumFromInt(1), .generation = 1 },
        .dialect = .unknown,
        .protocol = .http11,
        .key = .{ .connection_id = 1, .stream_id = 0 },
        .side = .request,
        .head = .init(gpa, 16),
        .body = .init(gpa, 16),
        .started_at_ms = 0,
    };
    try std.testing.expect(capture.body.append("owned capture"));
    try loop.select.concurrent(.proxy_capture, finishCapture, .{capture});

    var sockets: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
    var peer: core.SocketChannel = .init(.{ .socket = .{ .handle = sockets[1], .address = .{ .ip4 = .loopback(0) } } });
    defer peer.deinit(std.testing.io);
    const accepted: core.SocketChannel = .init(.{ .socket = .{ .handle = sockets[0], .address = .{ .ip4 = .loopback(0) } } });
    try loop.select.concurrent(.accepted, finishAccept, .{accepted});
    // Awaiting this group leaves the completed values in Select's queue.
    try loop.select.group.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 16), quota.used());

    loop.cancel();
    loop.cancel();
    try std.testing.expectEqual(@as(usize, 0), quota.used());
    try std.testing.expectEqual(@as(u64, 0), heap.snapshot().live_allocs);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), std.c.recv(peer.stream.socket.handle, &byte, byte.len, std.c.MSG.DONTWAIT));
    try std.testing.expectError(error.Closed, loop.select.queue.getOneUncancelable(std.testing.io));
}

test "loop cancellation joins the last producer when every event slot is occupied" {
    const loop = try std.testing.allocator.create(Loop);
    defer std.testing.allocator.destroy(loop);
    loop.init(std.testing.io, null);
    defer loop.cancel();
    var heap: core.Heap = .init(std.testing.allocator);
    for (0..loop.storage.len - 1) |_| {
        try loop.select.queue.putOne(std.testing.io, .{ .stopped = {} });
    }
    try loop.select.concurrent(.plugin_effects, finishPlugin, .{try pluginResult(heap.allocator())});

    loop.cancel();
    try std.testing.expectEqual(@as(u64, 0), heap.snapshot().live_allocs);
    try std.testing.expectError(error.Closed, loop.select.queue.getOneUncancelable(std.testing.io));
}

test "loop cancellation leaves model-retained job results for their owner" {
    const loop = try std.testing.allocator.create(Loop);
    defer std.testing.allocator.destroy(loop);
    loop.init(std.testing.io, null);
    defer loop.cancel();
    var heap: core.Heap = .init(std.testing.allocator);
    var job: ReviewJob = .{
        .service = undefined,
        .context = undefined,
        .client = null,
        .request_id = .none,
        .wire_len = 0,
        .result = try ReviewResult.init(heap.allocator()),
    };
    defer job.deinit();
    const owned = job.result.?;
    const before = heap.snapshot().live_allocs;
    try loop.select.queue.putOne(std.testing.io, .{ .change_review_completed = &job });

    loop.cancel();
    try std.testing.expect(job.result == owned);
    try std.testing.expectEqual(before, heap.snapshot().live_allocs);
    job.deinit();
    try std.testing.expectEqual(@as(u64, 0), heap.snapshot().live_allocs);
}

test "closing clients retain their search slot until the matching wake retires it" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    const key = fixture.session.key;
    try fixture.send(.{ .search_pane = .{ .request_id = @enumFromInt(41), .pane_id = pane.id, .needle = "search" } });
    fixture.session.send_pending = false;
    fixture.runtime.application.dropClient(key);
    try std.testing.expect(fixture.session.closing);
    try std.testing.expect(fixture.session.search_scheduled);
    try std.testing.expect(fixture.runtime.application.clients.resolve(key) != null);
    var stale = key;
    stale.generation += 1;
    try std.testing.expect(!try fixture.runtime.update(.{ .pane_search = .{ .client = stale, .request_id = @enumFromInt(41) } }));
    try std.testing.expect(fixture.session.search_scheduled);

    while (true) {
        const completed = try fixture.runtime.loop.next();
        _ = try fixture.runtime.update(completed);
        if (completed == .pane_search) {
            break;
        }
    }
    try std.testing.expect(fixture.runtime.application.clients.resolve(key) == null);
}

test "a failed search wake retires a closing session without admitting more work" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const key = fixture.session.key;
    fixture.session.search_scheduled = true;
    fixture.session.send_pending = false;
    fixture.runtime.application.dropClient(key);
    try std.testing.expect(fixture.runtime.application.clients.resolve(key) != null);

    try std.testing.expect(!try fixture.runtime.update(.{ .pane_search = .{
        .client = key,
        .request_id = @enumFromInt(41),
        .result = error.Canceled,
    } }));
    try std.testing.expect(fixture.runtime.application.clients.resolve(key) == null);
}

test "failed search admission cannot retain a closing client slot" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.failScheduling();
    const session = fixture.request.session;
    try std.testing.expectError(error.ConcurrencyUnavailable, pane_search.start(fixture.application, session, .{
        .request_id = @enumFromInt(41),
        .pane_id = fixture.pane.id,
        .needle = "search",
    }));
    try std.testing.expect(!session.search_scheduled);
    try std.testing.expect(session.pending_search == null);
    const key = session.key;
    session.send_pending = false;
    fixture.application.dropClient(key);
    try std.testing.expect(fixture.application.clients.resolve(key) == null);
}
