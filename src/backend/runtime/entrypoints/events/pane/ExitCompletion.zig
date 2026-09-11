const PaneKeyType = @import("../../../../pane/PaneKey.zig");
const exit = @import("../../../../pty/exit.zig");
const Completion = @This();

pane: PaneKeyType,
result: anyerror!exit.Exit,
