const bar_values = @import("../bars/model.zig");
const core = @import("telar-core");
const std = @import("std");
/// A command opened in its own transient tab. The tab closes when the
/// command exits, like a popup that borrows tab machinery instead of
/// floating chrome. Its argv holds as much as a bar command's; the
/// configuration keeps it in `CommandTabs` and an action names it by
/// `CommandTabRef`, so the Action union stays small.
const CommandTab = @This();

pub const max_arguments = bar_values.max_command_args;
pub const max_command_bytes = bar_values.max_command_bytes;
pub const max_label_bytes = 32;

pub const arguments_limit = core.Limit.declare("command_tab.max_arguments", "arguments", max_arguments);
pub const command_bytes_limit = core.Limit.declare("command_tab.max_command_bytes", "argv bytes", max_command_bytes);

argument_storage: [max_command_bytes]u8 = undefined,
argument_lens: [max_arguments]u16 = undefined,
argument_count: u8 = 0,
label_storage: [max_label_bytes]u8 = undefined,
label_len: u8 = 0,

/// Copies a bounded argv and optional label. An empty label derives from
/// the command's basename at render time. An argv past its limits fails
/// whole: a command is never cut.
///
/// ```zig
/// const command = try CommandTab.init(&.{"lazygit"}, "git");
/// ```
pub fn init(arguments: []const []const u8, tab_label: []const u8) !CommandTab {
    if (arguments.len == 0) {
        return error.InvalidCommand;
    }

    if (arguments.len > max_arguments) {
        return error.TooManyArguments;
    }

    if (tab_label.len > max_label_bytes) {
        return error.InvalidTabLabel;
    }

    var command: CommandTab = .{
        .argument_count = @intCast(arguments.len),
    };
    var offset: usize = 0;
    for (arguments, 0..) |item, index| {
        if (item.len == 0 or std.mem.indexOfScalar(u8, item, 0) != null) {
            return error.InvalidCommand;
        }

        if (offset + item.len > max_command_bytes) {
            return error.ArgumentsTooLarge;
        }

        @memcpy(command.argument_storage[offset .. offset + item.len], item);
        command.argument_lens[index] = @intCast(item.len);
        offset += item.len;
    }

    @memcpy(command.label_storage[0..tab_label.len], tab_label);
    command.label_len = @intCast(tab_label.len);
    return command;
}

pub fn argument(self: *const CommandTab, index: usize) []const u8 {
    var offset: usize = 0;
    for (0..index) |prior| {
        offset += self.argument_lens[prior];
    }

    return self.argument_storage[offset .. offset + self.argument_lens[index]];
}

/// The configured label, or the command basename.
///
/// ```zig
/// const label = command.label();
/// ```
pub fn label(self: *const CommandTab) []const u8 {
    if (self.label_len != 0) {
        return self.label_storage[0..self.label_len];
    }

    return std.fs.path.basename(self.argument(0));
}

/// Whether two commands run the same argv under the same label.
/// Example: `if (existing.eql(&command)) return index;`
pub fn eql(self: *const CommandTab, other: *const CommandTab) bool {
    if (self.argument_count != other.argument_count or !std.mem.eql(u8, self.label_storage[0..self.label_len], other.label_storage[0..other.label_len])) {
        return false;
    }

    const lens = self.argument_lens[0..self.argument_count];
    if (!std.mem.eql(u16, lens, other.argument_lens[0..other.argument_count])) {
        return false;
    }

    var bytes: usize = 0;
    for (lens) |len| {
        bytes += len;
    }

    return std.mem.eql(u8, self.argument_storage[0..bytes], other.argument_storage[0..bytes]);
}
