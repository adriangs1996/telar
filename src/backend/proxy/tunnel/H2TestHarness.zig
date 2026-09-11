const TestHarness = @This();
const Capture = @import("H2Capture.zig");
const middleware = @import("../middleware.zig");
const metrics = @import("../metrics.zig");
const exchange_mod = @import("exchange_support.zig");
const std = @import("std");
const source_namespace = @import("h2.zig");
const identity = @import("../identity.zig");
const ExpectedObservation = @import("ExpectedObservation.zig");
capture: Capture = .{},
pipeline: middleware.Pipeline = .{},
counters: metrics.Counters = .{},
exchange: exchange_mod.Exchange = undefined,

pub fn init(harness: *TestHarness) !void {
    try harness.pipeline.add(.{ .context = &harness.capture, .observe = Capture.observe });
    harness.exchange = .{
        .io = std.testing.io,
        .pipeline = &harness.pipeline,
        .telemetry = &harness.counters,
        .credential = .{
            .pane_id = try source_namespace.schema.id.pane(13),
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

pub fn snapshot(harness: *const TestHarness) metrics.Snapshot {
    return harness.counters.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    });
}
