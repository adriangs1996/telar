const ExitObservation = @This();
const source_namespace = @import("terminal.zig");
clock: source_namespace.Clock,
exit_code: i32,
