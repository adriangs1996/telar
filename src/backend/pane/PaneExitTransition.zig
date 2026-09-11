const Pane = @import("Pane.zig");
const exit_module = @import("../pty/exit.zig");
const PaneExitTransition = @This();

pane: *Pane,
exit: exit_module.Exit,
launch_aborting: bool,
output_done: bool,
