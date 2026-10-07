//! The command palette: one prompt field whose first byte selects what the
//! rest of the text searches. `>` filters the built-in action catalogue,
//! `@` reuses the goto picker over workspaces, tabs and agents, `?` asks
//! the command-suggestion engine, and `:` lists the window's machines. Text without a recognised prefix behaves
//! like `@`, so deleting the prefix never leaves the palette without a mode.

const core = @import("telar-core");
const CommandEntry = @import("CommandEntry.zig");
const CommandResults = @import("CommandResults.zig");

pub const Prefix = @import("CommandPalettePrefix.zig").CommandPalettePrefix;

/// Built-in actions in palette order. Every entry routes through the same
/// action dispatch as its key binding; there is no palette-only side effect.
/// `detach` is absent: it ends the input loop through the router's stop
/// control, which the prompt path cannot return.
pub const entries = [_]CommandEntry{
    .{ .action = .{ .split_pane = .horizontal }, .label = "Split right" },
    .{ .action = .{ .split_pane = .vertical }, .label = "Split down" },
    .{ .action = .{ .focus_pane = .left }, .label = "Focus pane left" },
    .{ .action = .{ .focus_pane = .right }, .label = "Focus pane right" },
    .{ .action = .{ .focus_pane = .up }, .label = "Focus pane up" },
    .{ .action = .{ .focus_pane = .down }, .label = "Focus pane down" },
    .{ .action = .toggle_pane_fullscreen, .label = "Toggle pane fullscreen" },
    .{ .action = .close_pane, .label = "Close pane" },
    .{ .action = .new_tab, .label = "New tab" },
    .{ .action = .rename_tab, .label = "Rename tab" },
    .{ .action = .close_tab, .label = "Close tab" },
    .{ .action = .{ .select_tab_offset = 1 }, .label = "Next tab" },
    .{ .action = .{ .select_tab_offset = -1 }, .label = "Previous tab" },
    .{ .action = .{ .move_tab = .previous }, .label = "Move tab left" },
    .{ .action = .{ .move_tab = .next }, .label = "Move tab right" },
    .{ .action = .new_workspace, .label = "New context" },
    .{ .action = .rename_workspace, .label = "Rename context" },
    .{ .action = .toggle_sidebar, .label = "Toggle sidebar" },
    .{ .action = .toggle_workspace_list, .label = "Toggle context list" },
    .{ .action = .leave_worktree, .label = "Leave worktree for its project" },
    .{ .action = .forget_gone_worktrees, .label = "Forget gone worktrees" },
    .{ .action = .enter_copy_mode, .label = "Enter copy mode" },
    .{ .action = .history_palette, .label = "Search command history" },
    .{ .action = .suggest_command, .label = "Suggest a command…" },
    .{
        .action = .path_picker,
        .label = "Insert a path",
    },
    .{ .action = .machine_picker, .label = "Switch machine" },
    .{ .action = .{ .select_machine_offset = 1 }, .label = "Next machine" },
    .{ .action = .{ .select_machine_offset = -1 }, .label = "Previous machine" },
    .{ .action = .add_machine, .label = "Add machine" },
};

/// The mode the field text selects. Example: `switch (prefixOf(text)) { ... }`.
pub fn prefixOf(text: []const u8) Prefix {
    if (text.len == 0) {
        return .goto;
    }

    return Prefix.parse(text[0]) orelse .goto;
}

/// The searchable text after a recognised prefix.
/// Example: `collect(sources, query(prompt.field.text()), &results);`.
pub fn query(text: []const u8) []const u8 {
    if (text.len == 0 or Prefix.parse(text[0]) == null) {
        return text;
    }

    return text[1..];
}

/// Fills `results` with every catalogue entry matching `needle`, best score
/// first and catalogue order among equal scores. Uses the fuzzy scorer the
/// goto picker and the runtime history share.
///
/// ```zig
/// var results: CommandResults = .{};
/// collect("split", &results);
/// ```
pub fn collect(needle: []const u8, results: *CommandResults) void {
    results.len = 0;
    for (entries, 0..) |entry, index| {
        const item_score = core.score(entry.label, needle) orelse continue;
        var at: usize = results.len;
        while (at > 0 and results.matches[at - 1].score < item_score) {
            at -= 1;
        }

        var move: usize = results.len;
        while (move > at) : (move -= 1) {
            results.matches[move] = results.matches[move - 1];
        }

        results.matches[at] = .{ .index = @intCast(index), .score = item_score };
        results.len += 1;
    }
}
