const vt = @import("ghostty-vt");

cwd: []const u8,
terminal: *vt.Terminal,
capture_output: bool = false,
