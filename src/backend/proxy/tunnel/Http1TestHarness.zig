const core = @import("telar-core");
const Http1Capture = @import("Http1Capture.zig");
const Pipeline = @import("../Pipeline.zig");
const Counters = @import("../Counters.zig");
const Exchange = @import("Exchange.zig");
const std = @import("std");
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const Snapshot = @import("../Snapshot.zig");
const TestHarness = @This();

capture: Http1Capture = .{},
pipeline: Pipeline = .{},
counters: Counters = .{},
exchange: Exchange = undefined,

pub fn init(harness: *TestHarness) !void {
    try harness.pipeline.add(.{ .context = &harness.capture, .observe = Http1Capture.observe });
    harness.exchange = .{
        .io = std.testing.io,
        .pipeline = &harness.pipeline,
        .telemetry = &harness.counters,
        .credential = .{
            .pane_id = try core.pane(7),
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

pub fn snapshot(harness: *const TestHarness) Snapshot {
    return harness.counters.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    });
}
