const Adapter = @This();
const Capture = @import("Capture.zig");
const source_namespace = @import("runtime_messages_tests.zig");
pub fn apply(capture: *Capture, _: anytype) !source_namespace.Outcome {
    capture.calls += 1;
    return capture.outcome;
}

pub fn failed(capture: *Capture, _: anytype) bool {
    return capture.history_failure;
}

pub fn output(capture: *Capture, _: anytype) source_namespace.Outcome {
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
