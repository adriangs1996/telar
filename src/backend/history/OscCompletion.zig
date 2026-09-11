const Completion = @This();
const Clock = @import("Clock.zig");
const source_namespace = @import("osc.zig");
clock: Clock,
exit_code: ?i32,
status: source_namespace.Status,
