const ClockType = @import("Clock.zig");
const InputObservation = @This();

bytes: []const u8,
shell_foreground: bool,
clock: ClockType,
