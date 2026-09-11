const ClockType = @import("Clock.zig");
const Output = @This();

offset: u32,
len: u32,
shell_foreground: ?bool,
clock: ClockType,
