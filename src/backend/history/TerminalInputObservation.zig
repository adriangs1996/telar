const vt = @import("ghostty-vt");
const Clock = @import("Clock.zig");
const InputObservation = @This();

terminal: *vt.Terminal,
bytes: []const u8,
shell_foreground: bool,
clock: Clock,
