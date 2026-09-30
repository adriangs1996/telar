//! One pick-list command the adapter runs off the interactive path: the
//! command that prints a list's options, or the `on_select` that receives
//! the chosen one.
const data = @import("model");
const PickCommandJob = @This();

pub const Purpose = enum {
    /// Prints the options; its output fills the list.
    list,
    /// Receives the choice; only its exit status matters.
    select,
};

execution_id: data.command_execution.Id,
purpose: Purpose,
command: data.BarCommand,
