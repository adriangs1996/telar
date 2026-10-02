//! What a `--help` on the command line asks for: the whole CLI, one family
//! or one command of it.

const CommandFamily = @import("arguments/CommandFamily.zig").CommandFamily;
const CommandHelp = @import("CommandHelp.zig");

pub const HelpTopic = union(enum) {
    root,
    family: CommandFamily,
    command: struct {
        family: CommandFamily,
        command: *const CommandHelp,
    },
};
