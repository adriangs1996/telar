//! Maps host key and paste events to name-prompt commands.
const keyinput = @import("keyinput");

const data = @import("model");

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
