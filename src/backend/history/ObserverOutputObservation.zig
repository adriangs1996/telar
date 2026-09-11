const ClockType = @import("Clock.zig");
const OutputObservation = @This();

bytes: []const u8,
shell_foreground: ?bool,
clock: ClockType,
