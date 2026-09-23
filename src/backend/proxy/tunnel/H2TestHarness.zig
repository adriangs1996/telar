const core = @import("telar-core");
const MiddlewareEvent = @import("../MiddlewareEvent.zig");
const Pipeline = @import("../Pipeline.zig");
const Counters = @import("../Counters.zig");
const Exchange = @import("Exchange.zig");
const std = @import("std");
const identity = @import("../identity.zig");
const ExpectedObservation = @import("ExpectedObservation.zig");
const Snapshot = @import("../Snapshot.zig");
const TestHarness = @This();

capture: H2Capture = .{},
pipeline: Pipeline = .{},
counters: Counters = .{},
exchange: Exchange = undefined,

pub fn init(self: *TestHarness) !void {
    try self.pipeline.add(.{ .context = &self.capture, .observe = H2Capture.observe });
    self.exchange = .{
        .io = std.testing.io,
        .pipeline = &self.pipeline,
        .telemetry = &self.counters,
        .credential = .{
            .pane_id = try core.pane(13),
            .pane_generation = 17,
            .token = .{0x24} ** identity.token_bytes,
        },
        .dialect = .anthropic_messages,
        .connection_id = 29,
        .protocol = .h2,
    };
}

pub fn expectObservations(self: *const TestHarness, expected: []const ExpectedObservation) !void {
    try std.testing.expectEqual(expected.len, self.capture.len);

    for (expected, self.capture.events[0..self.capture.len]) |wanted, event| {
        try std.testing.expectEqual(wanted.phase, event.phase);
        try std.testing.expectEqual(wanted.stream_id, event.stream_id);
    }
}

pub fn snapshot(self: *const TestHarness) Snapshot {
    return self.counters.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    });
}

const H2Capture = struct {
    events: [16]MiddlewareEvent = undefined,
    len: usize = 0,

    pub fn observe(context: *anyopaque, _: std.Io, event: MiddlewareEvent) void {
        const observed: *H2Capture = @ptrCast(@alignCast(context));
        observed.events[observed.len] = event;
        observed.len += 1;
    }
};
