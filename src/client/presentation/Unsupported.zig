const Fixture = @import("Fixture.zig");
const headless_tests = @import("headless_tests.zig");
const Unsupported = @This();

pub fn apply(_: *Fixture, _: anytype) !headless_tests.Outcome {
    return error.UnsupportedTestEvent;
}
pub fn failed(_: *Fixture, _: anytype) bool {
    return false;
}
pub fn output(_: *Fixture, _: anytype) headless_tests.Outcome {
    @panic("unsupported test event");
}
pub const applyCwd = apply;
pub const applyForeground = apply;
pub const applyTitle = apply;
pub const applyExit = apply;
pub const applyRuntime = apply;
pub const applyDeliveryReport = apply;
pub const matches = apply;
pub const pruned = apply;
