//! Paired mechanism probes; timings are diagnostic, never correctness thresholds.

const core = @import("telar-core");
const std = @import("std");
const PaneFixture = @import("PaneFixture.zig");
const pane_mod = @import("../../pane/pane_namespace.zig");
const Cursor = @import("../../pane/Cursor.zig");
const attachment_mod = @import("../attachment/attachment_namespace.zig");
const Stats = @import("../../media/Stats.zig");
const system_metrics = @import("../observability/system_metrics.zig");
const RequestFixture = @import("RequestFixture.zig");
const FakeSession = @import("../../proxy/http/FakeSession.zig");
const Session = @import("../../proxy/Session.zig");
const Fragment = @import("../../proxy/http/Fragment.zig");
const body = @import("../../proxy/http/body.zig");
const Service = @import("../../history/Service.zig");
const Query = @import("../../history/Query.zig");
const model_module = @import("../../history/model.zig");

fn now() i96 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
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
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.pane.resize(.{ .cols = 128, .rows = 5 });
    const row = ([_]u8{'a'} ** 127) ++ "\r\n";
    for (0..1000) |_| {
        _ = try fixture.pane.ingest(std.testing.io, row);
    }
    const needle = ([_]u8{'a'} ** 63) ++ "b";
    var matches: [core.max_search_matches]core.SearchMatch = undefined;
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
            var cursor = Cursor.init(needle);
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
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    const media = pane.media_allocator.allocator();
    const pixels = try media.alloc(u8, 3840 * 2160 * 4);
    @memset(pixels, 127);
    const screen = pane.media.terminal.screens.active;
    try screen.kitty_images.addImage(std.testing.io, media, screen, .{
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
        attachment.graphics.credit = core.max_image_bytes_per_pane;
        const started = now();
        const result = try attachment_mod.stageNextTransfer(attachment, core.max_image_bytes_global);
        stage.* = elapsed(started);
        if (result == .blocked) {
            const borrow = pane.beginMediaProcessing().?;
            var stats: Stats = .{};
            pane.processMedia(borrow.current_size, &stats);
            pane.completeMediaProcessing();
            const adoption_started = now();
            try std.testing.expectEqual(attachment_mod.StageResult.staged, try attachment_mod.stageNextTransfer(attachment, core.max_image_bytes_global));
            stage.* = @max(stage.*, elapsed(adoption_started));
        }
        total.* = elapsed(started);
        try std.testing.expectEqualSlices(u8, pixels, attachment.graphics.transfer.?.pixels);
        attachment.graphics.freeTransfer();
    }
    report("graphics_runtime_stage_4k", &stage_times);
    report("graphics_total_prepare_4k", &total_times);
}

test "performance probe counts work while host sampling is blocked or unchanged" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    model.system_metrics_pending = true;
    const before = model.system_metrics;
    const started = now();
    for (0..100) |_| {
        _ = try fixture.runtime.update(.{ .metrics_tick = {} });
    }
    try std.testing.expect(model.system_metrics_pending);
    try std.testing.expectEqualDeep(before, model.system_metrics);
    std.debug.print("PERF metrics_pending_ticks ticks=100 elapsed_ns={d}\n", .{elapsed(started)});
}

test "performance probe counts TLS-facing writes without changing chunk framing" {
    const encoded = "100\r\n" ++ ([_]u8{'x'} ** 256) ++ "\r\n0\r\nX-T: done\r\n\r\n";
    var counted: CountedRelay = .{ .fake = .{ .origin_input = encoded } };
    try std.testing.expect(body.relay(&counted, .{ .from = .origin, .to = .child, .framing = .chunked }, &counted));
    try std.testing.expectEqualStrings(encoded, counted.fake.childOutput());
    std.debug.print("PERF chunk_framing wire_bytes={d} tls_facing_writes={d}\n", .{ encoded.len, counted.writes });
}

test "performance probe executes a queued history burst and preserves every correlation" {
    var service = try Service.init(std.testing.allocator, .{ .database_path = ":memory:" });
    defer service.deinit(std.testing.io);
    for (1..33) |id| {
        const query = try Query.init(.{
            .request_id = @enumFromInt(id),
            .origin = .{ .client = .{ .id = 1, .generation = 1 }, .close_after_reply = false },
            .text = "needle",
        });
        try std.testing.expect(service.query(std.testing.io, query));
    }
    const started = now();
    var worker = try std.testing.io.concurrent(Service.run, .{ &service, std.testing.io });
    defer {
        service.stop(std.testing.io);
        worker.await(std.testing.io) catch {};
    }
    for (1..33) |id| {
        const response = try service.receiveResponse(std.testing.io);
        defer model_module.deinitResponse(response, std.testing.allocator);
        const request_id = switch (response) {
            .failed => |failure| failure.request_id,
            .query_result => |result| result.request_id,
            else => return error.UnexpectedResponse,
        };
        try std.testing.expectEqual(@as(core.RequestId, @enumFromInt(id)), request_id);
        if (id == 32) {
            try std.testing.expect(response == .query_result);
        }
    }
    std.debug.print("PERF history_burst queued=32 sqlite_queries={d} elapsed_ns={d}\n", .{ service.statsSnapshot().sqlite_queries, elapsed(started) });
}

const CountedRelay = struct {
    fake: FakeSession,
    writes: usize = 0,

    /// Example: `const count = counted.read(.origin, buffer);`.
    pub fn read(self: *CountedRelay, side: Session.Side, bytes: []u8) ?usize {
        return self.fake.read(side, bytes);
    }

    /// Example: `const forwarded = counted.writeAll(.child, bytes);`.
    pub fn writeAll(self: *CountedRelay, side: Session.Side, bytes: []const u8) bool {
        self.writes += 1;
        return self.fake.writeAll(side, bytes);
    }

    /// Example: `counted.observe(fragment);`.
    pub fn observe(_: *CountedRelay, _: Fragment) void {}
};
