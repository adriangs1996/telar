const media_ops = @import("media.zig");
const StatsType = @import("Stats.zig");
const MediaWork = @import("MediaWork.zig");
const std = @import("std");
const PaneType = @import("../../../../pane/Pane.zig");
const Capture = @This();

steps: [7]media_ops.Step = undefined,
len: usize = 0,
start_failure: bool = false,
response_failure: bool = false,
projection: StatsType = .{},
reset: bool = false,
synchronize_saw_idle_media: bool = false,
synchronize_saw_projection: bool = false,
start_saw_borrow: bool = false,
started_work: ?MediaWork = null,

fn record(capture: *Capture, step: media_ops.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn start(capture: *Capture, work: MediaWork) !void {
    capture.record(.media);
    capture.started_work = work;
    capture.start_saw_borrow = work.pane.media.worker != null and work.pane.actor_count != 0;

    if (capture.start_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn enforceQuotas(capture: *Capture, _: *PaneType) void {
    capture.record(.quotas);
}

pub fn synchronizeClients(capture: *Capture, pane: *PaneType, reset: bool) StatsType {
    capture.record(.synchronize_clients);
    capture.reset = reset;
    capture.synchronize_saw_idle_media = pane.media.worker == null;
    capture.synchronize_saw_projection = pane.graphics_present and pane.graphics_revision != 0;
    return capture.projection;
}

pub fn scheduleResponse(capture: *Capture, _: *PaneType) !void {
    capture.record(.response);

    if (capture.response_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn pumpClients(capture: *Capture) void {
    capture.record(.pump_clients);
}

pub fn collect(capture: *Capture) void {
    capture.record(.collect);
}
