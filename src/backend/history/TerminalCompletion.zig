const Completion = @This();
const source_namespace = @import("terminal.zig");
clock: source_namespace.Clock,
exit_code: ?i32,
status: source_namespace.Status,
