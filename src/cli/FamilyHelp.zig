//! What `telar FAMILY --help` prints: the family's purpose, the commands it
//! offers and the semantics they share.

const std = @import("std");
const CommandHelp = @import("CommandHelp.zig");
const FamilyHelp = @This();

/// One line for the root listing.
summary: []const u8,
/// The family's syntax, starting with `telar FAMILY`.
usage: []const u8,
/// What every command of the family shares: targets, identities, who owns
/// what. Empty when the commands say it all.
text: []const u8 = "",
commands: []const CommandHelp,

/// The command spelled `name`, if the family has it.
///
/// ```zig
/// const command = help.family(.worktree).find("create") orelse return null;
/// ```
pub fn find(self: FamilyHelp, name: []const u8) ?*const CommandHelp {
    for (self.commands) |*command| {
        if (std.mem.eql(u8, command.name, name)) {
            return command;
        }
    }

    return null;
}
