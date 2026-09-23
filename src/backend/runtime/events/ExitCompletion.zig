const PaneKey = @import("../../pane/PaneKey.zig");
const exit = @import("../../pty/exit.zig");
const Completion = @This();

pane: PaneKey,
result: anyerror!exit.Exit,
