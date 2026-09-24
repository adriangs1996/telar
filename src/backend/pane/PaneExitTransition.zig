const Pane = @import("Pane.zig");
const pty = @import("pty");
const exit_module = pty.exit;
const PaneExitTransition = @This();

pane: *Pane,
exit: exit_module.Exit,
launch_aborting: bool,
output_done: bool,
