const Clock = @import("Clock.zig");
const osc = @import("osc.zig");
const Completion = @This();

clock: Clock,
exit_code: ?i32,
status: osc.Status,
