const telemetry_tick_coordinator = @import("telemetry_tick_coordinator.zig");
const std = @import("std");
const StateType = @import("State.zig");
const Capture = @This();

steps: [5]telemetry_tick_coordinator.Step = undefined,
len: usize = 0,
sink_available: bool = true,
failure: ?telemetry_tick_coordinator.Step = null,
line: []const u8 = "sample\n",
format_buffer_len: usize = 0,
write_saw_pending: bool = false,
written_line: []const u8 = "",

fn record(capture: *Capture, step: telemetry_tick_coordinator.Step) !void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;

    if (capture.failure == step) {
        return error.SchedulerUnavailable;
    }
}

pub fn available(capture: *Capture, _: *const StateType) bool {
    capture.record(.available) catch unreachable;
    return capture.sink_available;
}

pub fn disable(capture: *Capture, _: *StateType) void {
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

pub fn scheduleWrite(capture: *Capture, state: *StateType, line: []const u8) !void {
    capture.write_saw_pending = state.writePending();
    capture.written_line = line;
    try capture.record(.write);
}
