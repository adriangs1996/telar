const ClockType = @import("Clock.zig");
const osc = @import("osc.zig");
const Completion = @This();

clock: ClockType,
exit_code: ?i32,
status: osc.Status,
