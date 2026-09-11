const Unsupported = @This();
const Fixture = @import("Fixture.zig");
const source_namespace = @import("headless_tests.zig");
pub fn apply(_: *Fixture, _: anytype) !source_namespace.Outcome {
    return error.UnsupportedTestEvent;
}
pub fn failed(_: *Fixture, _: anytype) bool {
    return false;
}
pub fn output(_: *Fixture, _: anytype) source_namespace.Outcome {
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
