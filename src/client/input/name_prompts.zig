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
/// Example: `const command = name_prompts.commandFor(&input, .pick) orelse return;`
pub fn commandFor(input: *const Input, target: ?data.name_prompt.Target) ?data.PromptCommand {
    if (target) |value| {
        if (data.name_prompt.selects(value) and input.* == .key) {
            const key = input.key;
            if (key.mods.ctrl and !key.mods.alt and !key.mods.shift and !key.mods.super and key.code == .char and key.code.char.len == 1) {
                switch (key.code.char.bytes[0]) {
                    'h' => return if (key.phase == .press) .cancel else null,
                    'l' => return if (key.phase == .press) .submit else null,
                    else => {},
                }
            }
        }
    }

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

    try std.testing.expectEqual(data.PromptCommand.move_down, commandFor(&.{ .key = down }, .pick).?);
    try std.testing.expectEqual(data.PromptCommand.move_up, commandFor(&.{ .key = up }, .pick).?);
}

test "ctrl+h and ctrl+l go back and choose only in list prompts" {
    for ([_]data.name_prompt.Target{ .palette, .pick, .goto, .history, .paths, .suggest }) |target| {
        var back: Input = .{ .key = try keyinput.chord.parseKey("ctrl+h") };
        var choose: Input = .{ .key = try keyinput.chord.parseKey("ctrl+l") };
        try std.testing.expectEqual(data.PromptCommand.cancel, commandFor(&back, target).?);
        try std.testing.expectEqual(data.PromptCommand.submit, commandFor(&choose, target).?);
        back.key.phase = .repeat;
        choose.key.phase = .repeat;
        try std.testing.expect(commandFor(&back, target) == null);
        try std.testing.expect(commandFor(&choose, target) == null);
        back.key.phase = .release;
        choose.key.phase = .release;
        try std.testing.expect(commandFor(&back, target) == null);
        try std.testing.expect(commandFor(&choose, target) == null);
    }

    for ([_][]const u8{ "ctrl+h", "ctrl+l", "alt+ctrl+h", "cmd+ctrl+l" }) |chord| {
        const input: Input = .{ .key = try keyinput.chord.parseKey(chord) };
        try std.testing.expect(commandFor(&input, .create_workspace) == null);
    }

    const backspace: Input = .{ .key = .plain(.backspace) };
    try std.testing.expectEqual(data.PromptCommand.backspace, commandFor(&backspace, .pick).?);
}

test "an inserted character borrows the caller's input, not a copy" {
    const input: Input = .{
        .key = .{
            .code = .{
                .char = keyinput.Char.init("m"),
            },
        },
    };
    const command = commandFor(&input, null).?;
    const inserted = command.insert;
    try std.testing.expectEqualStrings("m", inserted);
    try std.testing.expect(@intFromPtr(inserted.ptr) >= @intFromPtr(&input) and @intFromPtr(inserted.ptr) < @intFromPtr(&input) + @sizeOf(Input));
}
