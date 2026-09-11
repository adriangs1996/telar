const OutputObservation = @This();
const vt = @import("ghostty-vt");
const source_namespace = @import("terminal.zig");
/// The emulator that has already replayed `bytes`.
terminal: *vt.Terminal,
bytes: []const u8,
clock: source_namespace.Clock,
shell_foreground: ?bool,
