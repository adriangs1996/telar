const InputObservation = @This();
const vt = @import("ghostty-vt");
const source_namespace = @import("terminal.zig");
terminal: *vt.Terminal,
bytes: []const u8,
shell_foreground: bool,
clock: source_namespace.Clock,
