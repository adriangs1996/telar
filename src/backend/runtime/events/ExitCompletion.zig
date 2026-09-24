const PaneKey = @import("../../pane/PaneKey.zig");
const pty = @import("pty");
const exit = pty.exit;
const Completion = @This();

pane: PaneKey,
result: anyerror!exit.Exit,
