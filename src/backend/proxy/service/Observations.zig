const Pipeline = @import("../Pipeline.zig");
const Channel = @import("../Channel.zig");
const CredentialGate = @import("../CredentialGate.zig");
const std = @import("std");
const MiddlewareEvent = @import("../MiddlewareEvent.zig");
const ObservationQueueMetrics = @import("../ObservationQueueMetrics.zig");
const Observations = @This();

pipeline_value: Pipeline,
channel: Channel,

/// Wires one bounded channel into a fresh publication pipeline. The
/// component must already be at its final address because the pipeline
/// observer borrows its embedded channel.
///
/// ```zig
/// var observations: Observations = undefined;
/// try observations.init(liveness);
/// ```
pub fn init(self: *Observations, liveness: CredentialGate) !void {
    self.* = .{
        .pipeline_value = .{},
        .channel = undefined,
    };
    self.channel.init(liveness);
    try self.pipeline_value.add(self.channel.observer());
}

/// Closes delivery after all publishers have stopped.
///
/// ```zig
/// observations.close(io);
/// ```
pub fn close(self: *Observations, io: std.Io) void {
    self.channel.close(io);
}

/// Waits for the next queued event whose credential remains live.
///
/// ```zig
/// const event = try observations.receive(io);
/// ```
pub fn receive(self: *Observations, io: std.Io) anyerror!MiddlewareEvent {
    return self.channel.receive(io);
}

/// Borrows the immutable publication pipeline used by active tunnels.
///
/// ```zig
/// const pipeline = observations.pipeline();
/// ```
pub fn pipeline(self: *const Observations) *const Pipeline {
    return &self.pipeline_value;
}

/// Returns a lock-free snapshot of bounded queue behavior.
///
/// ```zig
/// const snapshot = observations.metrics();
/// ```
pub fn metrics(self: *const Observations) ObservationQueueMetrics {
    return self.channel.metrics();
}
