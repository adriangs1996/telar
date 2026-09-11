const PipelineType = @import("../Pipeline.zig");
const ChannelType = @import("../Channel.zig");
const Liveness = @import("Liveness.zig");
const std = @import("std");
const MiddlewareEvent = @import("../MiddlewareEvent.zig");
const ObservationQueueMetrics = @import("../ObservationQueueMetrics.zig");
const Observations = @This();

pipeline_value: PipelineType,
channel: ChannelType,

/// Wires one bounded channel into a fresh publication pipeline. The
/// component must already be at its final address because the pipeline
/// observer borrows its embedded channel.
///
/// ```zig
/// var observations: Observations = undefined;
/// try observations.init(liveness);
/// ```
pub fn init(observations: *Observations, liveness: Liveness) !void {
    observations.* = .{
        .pipeline_value = .{},
        .channel = undefined,
    };
    observations.channel.init(.{
        .context = liveness.context,
        .is_live = liveness.is_live,
    });
    try observations.pipeline_value.add(observations.channel.observer());
}

/// Closes delivery after all publishers have stopped.
///
/// ```zig
/// observations.close(io);
/// ```
pub fn close(observations: *Observations, io: std.Io) void {
    observations.channel.close(io);
}

/// Waits for the next queued event whose credential remains live.
///
/// ```zig
/// const event = try observations.receive(io);
/// ```
pub fn receive(observations: *Observations, io: std.Io) anyerror!MiddlewareEvent {
    return observations.channel.receive(io);
}

/// Borrows the immutable publication pipeline used by active tunnels.
///
/// ```zig
/// const pipeline = observations.pipeline();
/// ```
pub fn pipeline(observations: *const Observations) *const PipelineType {
    return &observations.pipeline_value;
}

/// Returns a lock-free snapshot of bounded queue behavior.
///
/// ```zig
/// const snapshot = observations.metrics();
/// ```
pub fn metrics(observations: *const Observations) ObservationQueueMetrics {
    return observations.channel.metrics();
}
