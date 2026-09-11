/// A command opened in its own transient tab. The tab closes when the
/// command exits, like a popup that borrows tab machinery instead of
/// floating chrome.
const CommandTab = @This();
const std = @import("std");
pub const max_arguments = 8;
pub const max_command_bytes = 224;
pub const max_label_bytes = 32;

argument_storage: [max_command_bytes]u8 = undefined,
argument_lens: [max_arguments]u8 = undefined,
argument_count: u8 = 0,
label_storage: [max_label_bytes]u8 = undefined,
label_len: u8 = 0,

/// Copies a bounded argv and optional label into inline storage. The
/// caps keep the Action union small enough for by-value keymaps. An
/// empty label derives from the command's basename at render time.
///
/// ```zig
/// const command = try CommandTab.init(&.{"lazygit"}, "git");
/// ```
pub fn init(arguments: []const []const u8, tab_label: []const u8) !CommandTab {
    if (arguments.len == 0 or arguments.len > max_arguments) {
        return error.InvalidCommand;
    }
    if (tab_label.len > max_label_bytes) {
        return error.InvalidTabLabel;
    }

    var command: CommandTab = .{ .argument_count = @intCast(arguments.len) };
    var offset: usize = 0;
    for (arguments, 0..) |item, index| {
        if (item.len == 0 or offset + item.len > max_command_bytes) {
            return error.InvalidCommand;
        }
        if (std.mem.indexOfScalar(u8, item, 0) != null) {
            return error.InvalidCommand;
        }
        @memcpy(command.argument_storage[offset .. offset + item.len], item);
        command.argument_lens[index] = @intCast(item.len);
        offset += item.len;
    }

    @memcpy(command.label_storage[0..tab_label.len], tab_label);
    command.label_len = @intCast(tab_label.len);
    return command;
}

pub fn argument(command: *const CommandTab, index: usize) []const u8 {
    var offset: usize = 0;
    for (0..index) |prior| {
        offset += command.argument_lens[prior];
    }

    return command.argument_storage[offset .. offset + command.argument_lens[index]];
}

/// The configured label, or the command basename.
///
/// ```zig
/// const label = command.label();
/// ```
pub fn label(command: *const CommandTab) []const u8 {
    if (command.label_len != 0) {
        return command.label_storage[0..command.label_len];
    }

    return std.fs.path.basename(command.argument(0));
}
