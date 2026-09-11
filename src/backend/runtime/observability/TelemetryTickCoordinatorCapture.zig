const Capture = @This();
const source_namespace = @import("telemetry_tick_coordinator.zig");
const std = @import("std");
steps: [5]source_namespace.Step = undefined,
len: usize = 0,
sink_available: bool = true,
failure: ?source_namespace.Step = null,
line: []const u8 = "sample\n",
format_buffer_len: usize = 0,
write_saw_pending: bool = false,
written_line: []const u8 = "",

fn record(capture: *Capture, step: source_namespace.Step) !void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;

    if (capture.failure == step) {
        return error.SchedulerUnavailable;
    }
}

pub fn available(capture: *Capture, _: *const source_namespace.State) bool {
    capture.record(.available) catch unreachable;
    return capture.sink_available;
}

pub fn disable(capture: *Capture, _: *source_namespace.State) void {
    capture.record(.disable) catch unreachable;
}

pub fn scheduleTick(capture: *Capture) !void {
    try capture.record(.tick);
}

pub fn formatSample(capture: *Capture, buffer: []u8) ![]const u8 {
    capture.format_buffer_len = buffer.len;
    try capture.record(.format);
    @memcpy(buffer[0..capture.line.len], capture.line);
    return buffer[0..capture.line.len];
}

pub fn scheduleWrite(capture: *Capture, state: *source_namespace.State, line: []const u8) !void {
    capture.write_saw_pending = state.writePending();
    capture.written_line = line;
    try capture.record(.write);
}
