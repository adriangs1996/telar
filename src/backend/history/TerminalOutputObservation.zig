const vt = @import("ghostty-vt");
const ClockType = @import("Clock.zig");
const OutputObservation = @This();

/// The emulator that has already replayed `bytes`.
terminal: *vt.Terminal,
bytes: []const u8,
clock: ClockType,
shell_foreground: ?bool,
