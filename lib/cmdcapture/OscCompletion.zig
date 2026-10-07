const Clock = @import("Clock.zig");
const osc = @import("osc.zig");

clock: Clock,
exit_code: ?i32,
status: osc.Status,
