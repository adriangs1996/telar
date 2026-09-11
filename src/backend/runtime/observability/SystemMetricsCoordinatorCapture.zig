const SamplerType = @import("Sampler.zig");
const Capture = @This();

rearms: usize = 0,
jobs: usize = 0,
pumps: usize = 0,
fail_rearm: bool = false,
fail_schedule: bool = false,
owned: SamplerType = .{},

pub fn rearm(capture: *Capture) !void {
    capture.rearms += 1;
    if (capture.fail_rearm) {
        return error.SchedulerUnavailable;
    }
}

pub fn schedule(capture: *Capture, sampler: SamplerType) !void {
    if (capture.fail_schedule) {
        return error.SchedulerUnavailable;
    }

    capture.jobs += 1;
    capture.owned = sampler;
}

pub fn pump(capture: *Capture) void {
    capture.pumps += 1;
}
