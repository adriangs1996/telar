const Capture = @import("Capture.zig");
const runtime_messages_tests = @import("runtime_messages_tests.zig");
const Adapter = @This();

pub fn apply(capture: *Capture, _: anytype) !runtime_messages_tests.Outcome {
    capture.calls += 1;
    return capture.outcome;
}

pub fn failed(capture: *Capture, _: anytype) bool {
    return capture.history_failure;
}

pub fn output(capture: *Capture, _: anytype) runtime_messages_tests.Outcome {
    capture.calls += 1;
    return capture.outcome;
}

pub const applyCwd = apply;
pub const applyForeground = apply;
pub const applyTitle = apply;
pub const applyExit = apply;
pub const applyRuntime = apply;
pub const applyDeliveryReport = apply;
pub const matches = apply;
pub const pruned = apply;
