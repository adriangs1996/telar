const Capture = @This();
const source_namespace = @import("media.zig");
const media_projection = @import("media_projection.zig");
const Work = @import("MediaWork.zig");
const std = @import("std");
steps: [7]source_namespace.Step = undefined,
len: usize = 0,
start_failure: bool = false,
response_failure: bool = false,
projection: media_projection.Stats = .{},
reset: bool = false,
synchronize_saw_idle_media: bool = false,
synchronize_saw_projection: bool = false,
start_saw_borrow: bool = false,
started_work: ?Work = null,

fn record(capture: *Capture, step: source_namespace.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn start(capture: *Capture, work: Work) !void {
    capture.record(.media);
    capture.started_work = work;
    capture.start_saw_borrow = work.pane.media.worker != null and work.pane.actor_count != 0;

    if (capture.start_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn enforceQuotas(capture: *Capture, _: *source_namespace.Pane) void {
    capture.record(.quotas);
}

pub fn synchronizeClients(capture: *Capture, pane: *source_namespace.Pane, reset: bool) media_projection.Stats {
    capture.record(.synchronize_clients);
    capture.reset = reset;
    capture.synchronize_saw_idle_media = pane.media.worker == null;
    capture.synchronize_saw_projection = pane.graphics_present and pane.graphics_revision != 0;
    return capture.projection;
}

pub fn scheduleResponse(capture: *Capture, _: *source_namespace.Pane) !void {
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
