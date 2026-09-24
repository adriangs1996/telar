const vt = @import("ghostty-vt");
const Config = @This();

cwd: []const u8,
terminal: *vt.Terminal,
capture_output: bool = false,
