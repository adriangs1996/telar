//! Every two seconds one worker samples host CPU, memory and battery; a
//! changed sample reaches clients that subscribed to runtime state.

const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Sources = @import("Sources.zig");
const hostmetrics = @import("hostmetrics");
const SystemMetricsSample = hostmetrics.SystemMetricsSample;
const sampler = hostmetrics.system_metrics;

/// Rearms the tick and admits at most one sampling job.
///
/// ```zig
/// try system_metrics.tick(model, result);
/// ```
pub fn tick(model: *RuntimeModel, result: anyerror!void) !void {
    result catch return;
    var sources = Sources.init(model.io, model.select);
    try sources.waitForSystemMetrics();
    if (model.system_metrics_pending) {
        return;
    }

    model.system_metrics_pending = true;
    errdefer model.system_metrics_pending = false;
    try model.select.concurrent(.metrics_sampled, sampler.sampleOwned, .{ model.io, model.system_metrics });
}

/// Commits one complete sample; its revision drives client delivery.
///
/// ```zig
/// system_metrics.finish(model, sample);
/// ```
pub fn finish(model: *RuntimeModel, sample: SystemMetricsSample) void {
    model.metrics.system_sample.observe(sample.duration_ns);
    model.metrics.system_sample_last_ns = sample.captured_ns;
    std.debug.assert(model.system_metrics_pending);
    model.system_metrics_pending = false;
    model.system_metrics = sample.sampler;
}
