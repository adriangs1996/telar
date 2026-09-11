//! Paired mechanism probes; timings are diagnostic, never correctness thresholds.
const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const history = @import("../../history/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const support = @import("support.zig");
const io = std.testing.io;

fn now() i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn elapsed(start: i96) u64 {
    return @intCast(now() - start);
}

fn report(name: []const u8, values: []u64) void {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    std.debug.print("PERF {s} n={d} p50_ns={d} p95_ns={d} p99_ns={d}\n", .{
        name, values.len, values[values.len / 2], values[(values.len * 95 + 99) / 100 - 1], values[values.len - 1],
    });
}

test "performance probe measures bounded search turns against the complete query" {
    var fixture: support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.pane.resize(.{ .cols = 128, .rows = 5 });
    const row = ([_]u8{'a'} ** 127) ++ "\r\n";
    for (0..1000) |_| {
        _ = try fixture.pane.ingest(io, row);
    }
    const needle = ([_]u8{'a'} ** 63) ++ "b";
    var matches: [core.schema.max_search_matches]core.schema.SearchMatch = undefined;
    var complete_times: [20]u64 = undefined;
    for (&complete_times) |*time| {
        const started = now();
        const found = fixture.pane.searchText(needle, &matches);
        time.* = elapsed(started);
        try std.testing.expectEqual(@as(u8, 0), found.count);
    }
    report("search_complete", &complete_times);

    if (comptime @hasDecl(pane_mod, "TextSearch")) {
        var total_times: [20]u64 = undefined;
        var turn_times: [20]u64 = undefined;
        for (&total_times, &turn_times) |*total, *turn_max| {
            var cursor = pane_mod.TextSearch.init(needle);
            turn_max.* = 0;
            const started = now();
            while (true) {
                const turn = now();
                const done = try cursor.advance(fixture.pane);
                turn_max.* = @max(turn_max.*, elapsed(turn));
                if (done) {
                    break;
                }
            }

            total.* = elapsed(started);
            try std.testing.expectEqual(@as(u8, 0), cursor.count);
        }
        report("search_incremental_total", &total_times);
        report("search_max_turn", &turn_times);
    }
}

test "performance probe measures runtime staging of a 4K RGBA transfer" {
    var fixture: support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    const media = pane.media_allocator.allocator();
    const pixels = try media.alloc(u8, 3840 * 2160 * 4);
    @memset(pixels, 127);
    const screen = pane.media.terminal.screens.active;
    try screen.kitty_images.addImage(io, media, screen, .{
        .id = 7,
        .width = 3840,
        .height = 2160,
        .format = .rgba,
        .data = .{ .complete = pixels },
    });
    pane.refreshGraphicsProjection();
    const attachment = fixture.attachments.find(pane.id).?;
    var stage_times: [20]u64 = undefined;
    var total_times: [20]u64 = undefined;
    for (&stage_times, &total_times) |*stage, *total| {
        attachment.graphics.credit = core.graphics.max_image_bytes_per_pane;
        const started = now();
        const result = try attachment_mod.stageNextTransfer(attachment, core.graphics.max_image_bytes_global);
        stage.* = elapsed(started);
        if (result == .blocked) {
            const borrow = pane.beginMediaProcessing().?;
            var stats: @import("../../media/root.zig").Stats = .{};
            pane.processMedia(borrow.current_size, &stats);
            pane.completeMediaProcessing();
            const adoption_started = now();
            try std.testing.expectEqual(attachment_mod.StageResult.staged, try attachment_mod.stageNextTransfer(attachment, core.graphics.max_image_bytes_global));
            stage.* = @max(stage.*, elapsed(adoption_started));
        }
        total.* = elapsed(started);
        try std.testing.expectEqualSlices(u8, pixels, attachment.graphics.transfer.?.pixels);
        attachment.graphics.freeTransfer();
    }
    report("graphics_runtime_stage_4k", &stage_times);
    report("graphics_total_prepare_4k", &total_times);
}

const MetricsCapture = @import("MetricsCapture.zig");

test "performance probe counts work while host sampling is blocked or unchanged" {
    const metrics = @import("../observability/system_metrics.zig");
    const coordinator = @import("../observability/system_metrics_coordinator.zig");
    const asynchronous = @hasDecl(metrics, "sampleOwned");
    const port: coordinator.RuntimePort(MetricsCapture) = if (asynchronous)
        .{ .rearm_tick = MetricsCapture.rearm, .schedule = MetricsCapture.schedule, .pump_clients = MetricsCapture.pump }
    else
        .{ .rearm_tick = MetricsCapture.rearm, .sample = MetricsCapture.sample, .pump_clients = MetricsCapture.pump };
    var sampler: metrics.Sampler = .{};
    var capture: MetricsCapture = .{};
    var pending = false;
    const resources: coordinator.Resources = if (asynchronous)
        .{ .sampler = &sampler, .pending = &pending }
    else
        .{ .sampler = &sampler };
    var handler = coordinator.Coordinator(MetricsCapture, port).init(&capture, resources);
    for (0..100) |_| {
        try handler.handle({});
    }
    std.debug.print("PERF metrics_ticks ticks=100 inline_reads={d} scheduled_jobs={d} client_pumps={d}\n", .{ capture.reads, capture.jobs, capture.pumps });
}

const CountedRelay = @import("CountedRelay.zig");

test "performance probe counts TLS-facing writes without changing chunk framing" {
    const encoded = "100\r\n" ++ ([_]u8{'x'} ** 256) ++ "\r\n0\r\nX-T: done\r\n\r\n";
    var counted: CountedRelay = .{ .fake = .{ .origin_input = encoded } };
    try std.testing.expect(@import("../../proxy/http/body.zig").relay(&counted, .{ .from = .origin, .to = .child, .framing = .chunked }, &counted));
    try std.testing.expectEqualStrings(encoded, counted.fake.childOutput());
    std.debug.print("PERF chunk_framing wire_bytes={d} tls_facing_writes={d}\n", .{ encoded.len, counted.writes });
}

test "performance probe executes a queued history burst and preserves every correlation" {
    var service = try history.Service.init(std.testing.allocator, .{ .database_path = ":memory:" });
    defer service.deinit(io);
    for (1..33) |id| {
        const query = try history.Query.init(.{
            .request_id = @enumFromInt(id),
            .origin = .{ .client = .{ .id = 1, .generation = 1 }, .close_after_reply = false },
            .text = "needle",
        });
        try std.testing.expect(service.query(io, query));
    }
    const started = now();
    var worker = try io.concurrent(history.Service.run, .{ &service, io });
    defer {
        service.stop(io);
        worker.await(io) catch {};
    }
    for (1..33) |id| {
        const response = try service.receiveResponse(io);
        defer history.model.deinitResponse(response, std.testing.allocator);
        const request_id = switch (response) {
            .failed => |failure| failure.request_id,
            .query_result => |result| result.request_id,
            else => return error.UnexpectedResponse,
        };
        try std.testing.expectEqual(@as(core.schema.RequestId, @enumFromInt(id)), request_id);
        if (id == 32) {
            try std.testing.expect(response == .query_result);
        }
    }
    std.debug.print("PERF history_burst queued=32 sqlite_queries={d} elapsed_ns={d}\n", .{ service.statsSnapshot().sqlite_queries, elapsed(started) });
}
