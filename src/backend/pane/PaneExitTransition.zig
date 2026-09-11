const PaneExitTransition = @This();
const Pane = @import("Pane.zig");
const pty = @import("../pty/root.zig");
pane: *Pane,
exit: pty.Exit,
launch_aborting: bool,
output_done: bool,
