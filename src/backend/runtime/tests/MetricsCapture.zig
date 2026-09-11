const SamplerType = @import("../observability/Sampler.zig");
const MetricsCapture = @This();

reads: usize = 0,
jobs: usize = 0,
pumps: usize = 0,

pub fn rearm(_: *MetricsCapture) !void {}

fn sample(capture: *MetricsCapture, _: *SamplerType) void {
    capture.reads += 1;
}

pub fn schedule(capture: *MetricsCapture, _: SamplerType) !void {
    capture.jobs += 1;
}

pub fn pump(capture: *MetricsCapture) void {
    capture.pumps += 1;
}
