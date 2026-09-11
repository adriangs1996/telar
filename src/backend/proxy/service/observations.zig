const Observations = @This();
const middleware = @import("../middleware.zig");
const observation_queue = @import("../observation_queue.zig");
const Liveness = @import("Liveness.zig");
const source_namespace = @import("observations_support.zig");
pipeline_value: middleware.Pipeline,
channel: observation_queue.Channel,

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
pub fn close(observations: *Observations, io: source_namespace.Io) void {
    observations.channel.close(io);
}

/// Waits for the next queued event whose credential remains live.
///
/// ```zig
/// const event = try observations.receive(io);
/// ```
pub fn receive(observations: *Observations, io: source_namespace.Io) anyerror!middleware.Event {
    return observations.channel.receive(io);
}

/// Borrows the immutable publication pipeline used by active tunnels.
///
/// ```zig
/// const pipeline = observations.pipeline();
/// ```
pub fn pipeline(observations: *const Observations) *const middleware.Pipeline {
    return &observations.pipeline_value;
}

/// Returns a lock-free snapshot of bounded queue behavior.
///
/// ```zig
/// const snapshot = observations.metrics();
/// ```
pub fn metrics(observations: *const Observations) observation_queue.Metrics {
    return observations.channel.metrics();
}
