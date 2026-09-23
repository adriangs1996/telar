const vt = @import("ghostty-vt");
const Clock = @import("Clock.zig");
const OutputObservation = @This();

/// The emulator that has already replayed `bytes`.
terminal: *vt.Terminal,
bytes: []const u8,
clock: Clock,
shell_foreground: ?bool,
