const TestHarness = @This();
const Capture = @import("Http1Capture.zig");
const middleware = @import("../middleware.zig");
const metrics = @import("../metrics.zig");
const exchange_mod = @import("exchange_support.zig");
const std = @import("std");
const source_namespace = @import("http1.zig");
const identity = @import("../identity.zig");
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
            .pane_id = try source_namespace.schema.id.pane(7),
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

pub fn snapshot(harness: *const TestHarness) metrics.Snapshot {
    return harness.counters.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    });
}
