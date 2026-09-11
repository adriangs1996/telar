const Http1Capture = @import("Http1Capture.zig");
const PipelineType = @import("../Pipeline.zig");
const CountersType = @import("../Counters.zig");
const ExchangeType = @import("Exchange.zig");
const std = @import("std");
const pane_module = @import("telar-core").pane;
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const SnapshotType = @import("../Snapshot.zig");
const TestHarness = @This();

capture: Http1Capture = .{},
pipeline: PipelineType = .{},
counters: CountersType = .{},
exchange: ExchangeType = undefined,

pub fn init(harness: *TestHarness) !void {
    try harness.pipeline.add(.{ .context = &harness.capture, .observe = Http1Capture.observe });
    harness.exchange = .{
        .io = std.testing.io,
        .pipeline = &harness.pipeline,
        .telemetry = &harness.counters,
        .credential = .{
            .pane_id = try pane_module(7),
            .pane_generation = 11,
            .token = .{0x42} ** identity.token_bytes,
        },
        .dialect = .anthropic_messages,
        .connection_id = 19,
        .protocol = .http11,
    };
}

pub fn expectPhases(harness: *const TestHarness, expected: []const middleware.Phase) !void {
    try std.testing.expectEqual(expected.len, harness.capture.len);

    for (expected, harness.capture.events[0..harness.capture.len]) |phase, event| {
        try std.testing.expectEqual(phase, event.phase);
    }
}

pub fn snapshot(harness: *const TestHarness) SnapshotType {
    return harness.counters.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    });
}
