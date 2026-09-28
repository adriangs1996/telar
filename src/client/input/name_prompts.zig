//! Maps host key and paste events to name-prompt commands.
const keyinput = @import("keyinput");

const data = @import("model");
const std = @import("std");

/// One semantic host event the prompt can interpret. Pasted text arrives as
/// bounded slices between the paste markers; the adapter decodes bytes.
pub const Input = union(enum) {
    command: data.PromptCommand,
    key: keyinput.Key,
    paste_start,
    paste_end,
    paste_text: []const u8,
};

/// Maps one semantic host event to a prompt command; events the prompt does
/// not interpret produce no command. An inserted character borrows the
/// caller's `input`, so it must outlive the command.
/// Example: `const command = name_prompts.commandFor(&input) orelse return;`
pub fn commandFor(input: *const Input) ?data.PromptCommand {
    return switch (input.*) {
        .command => |command| command,
        .paste_start => .paste_start,
        .paste_end => .paste_end,
        .paste_text => |text| .{ .insert = text },
        .key => |*key| switch (key.code) {
            .enter => if (key.mods.alt) .visit_pane else if (key.mods.shift) .submit_alternate else .submit,
            .escape => .cancel,
            .backspace => .backspace,
            .delete => .delete,
            .left => .{ .move_left = key.mods.shift },
            .right => .{ .move_right = key.mods.shift },
            .up => .move_up,
            .down => .move_down,
            .page_up => .page_up,
            .page_down => .page_down,
            .tab => .tab,
            .back_tab => .back_tab,
            .home => .{ .home = key.mods.shift },
            .end => .{ .end = key.mods.shift },
            .char => |*char| if (!key.mods.ctrl and !key.mods.alt)
                .{ .insert = char.slice() }
            else if (key.mods.ctrl and !key.mods.alt and char.slice().len == 1 and char.slice()[0] == 'd')
                .remove_entry
            else if (key.mods.ctrl and !key.mods.alt and char.slice().len == 1 and char.slice()[0] == 'o')
                .toggle_inspection
            else if (key.mods.ctrl and !key.mods.alt and char.slice().len == 1 and char.slice()[0] == 'c')
                .copy_entry
            else if (key.mods.ctrl and !key.mods.alt and char.slice().len == 1 and char.slice()[0] == 'r')
                .rename_entry
            // Vim-style list movement; a terminal sends Ctrl+J as LF, which
            // the host decoder keeps apart from Enter.
            else if (key.mods.ctrl and !key.mods.alt and char.slice().len == 1 and char.slice()[0] == 'j')
                .move_down
            else if (key.mods.ctrl and !key.mods.alt and char.slice().len == 1 and char.slice()[0] == 'k')
                .move_up
            else
                null,
        },
    };
}

test "ctrl+j and ctrl+k move a list selection like the arrows" {
    const down: keyinput.Key = .{
        .code = .{
            .char = keyinput.Char.init("j"),
        },
        .mods = .{
            .ctrl = true,
        },
    };
    const up: keyinput.Key = .{
        .code = .{
            .char = keyinput.Char.init("k"),
        },
        .mods = .{
            .ctrl = true,
        },
    };

    try std.testing.expectEqual(data.PromptCommand.move_down, commandFor(&.{ .key = down }).?);
    try std.testing.expectEqual(data.PromptCommand.move_up, commandFor(&.{ .key = up }).?);
}

test "an inserted character borrows the caller's input, not a copy" {
    const input: Input = .{
        .key = .{
            .code = .{
                .char = keyinput.Char.init("m"),
            },
        },
    };
    const command = commandFor(&input).?;
    const inserted = command.insert;
    try std.testing.expectEqualStrings("m", inserted);
    try std.testing.expect(@intFromPtr(inserted.ptr) >= @intFromPtr(&input) and @intFromPtr(inserted.ptr) < @intFromPtr(&input) + @sizeOf(Input));
}
