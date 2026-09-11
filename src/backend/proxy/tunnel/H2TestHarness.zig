const H2Capture = @import("H2Capture.zig");
const PipelineType = @import("../Pipeline.zig");
const CountersType = @import("../Counters.zig");
const ExchangeType = @import("Exchange.zig");
const std = @import("std");
const pane_module = @import("telar-core").pane;
const identity = @import("../identity.zig");
const ExpectedObservation = @import("ExpectedObservation.zig");
const SnapshotType = @import("../Snapshot.zig");
const TestHarness = @This();

capture: H2Capture = .{},
pipeline: PipelineType = .{},
counters: CountersType = .{},
exchange: ExchangeType = undefined,

pub fn init(harness: *TestHarness) !void {
    try harness.pipeline.add(.{ .context = &harness.capture, .observe = H2Capture.observe });
    harness.exchange = .{
        .io = std.testing.io,
        .pipeline = &harness.pipeline,
        .telemetry = &harness.counters,
        .credential = .{
            .pane_id = try pane_module(13),
            .pane_generation = 17,
            .token = .{0x24} ** identity.token_bytes,
        },
        .dialect = .anthropic_messages,
        .connection_id = 29,
        .protocol = .h2,
    };
}

pub fn expectObservations(harness: *const TestHarness, expected: []const ExpectedObservation) !void {
    try std.testing.expectEqual(expected.len, harness.capture.len);

    for (expected, harness.capture.events[0..harness.capture.len]) |wanted, event| {
        try std.testing.expectEqual(wanted.phase, event.phase);
        try std.testing.expectEqual(wanted.stream_id, event.stream_id);
    }
}

pub fn snapshot(harness: *const TestHarness) SnapshotType {
    return harness.counters.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    });
}
