//! Shell-independent command capture from a pane's rendered terminal state:
//! the command line, its working directory, exit status and a bounded output
//! tail. OSC 133 marks and OSC 7 directories, when a shell emits them, add
//! exit codes and the current directory. `rowIsBlank` says whether a
//! terminal row shows any text.

pub const Clock = @import("Clock.zig");
pub const Command = @import("Command.zig");
pub const TerminalTracker = @import("TerminalTracker.zig");
pub const rowIsBlank = @import("terminal.zig").rowIsBlank;

test {
    _ = @import("Clock.zig");
    _ = @import("Command.zig");
    _ = @import("OscCompletion.zig");
    _ = @import("OscTracker.zig");
    _ = @import("TerminalTracker.zig");
    _ = @import("TerminalTrackerConfig.zig");
    _ = @import("osc.zig");
    _ = @import("terminal.zig");
}
