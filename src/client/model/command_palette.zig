//! The command palette: one prompt field whose first byte selects what the
//! rest of the text searches. `>` filters the built-in action catalogue,
//! `@` reuses the goto picker over workspaces, tabs and agents, and `?` asks
//! the command-suggestion engine. Text without a recognised prefix behaves
//! like `@`, so deleting the prefix never leaves the palette without a mode.

const std = @import("std");
const score_module = @import("telar-core").score;
const CommandEntry = @import("CommandEntry.zig");
const CommandResults = @import("CommandResults.zig");

pub const Prefix = enum(u8) {
    actions = '>',
    goto = '@',
    suggest = '?',

    /// The byte the prefix occupies in the prompt field.
    /// Example: `field.init(&.{prefix.byte()})`.
    pub fn byte(prefix: Prefix) u8 {
        return @intFromEnum(prefix);
    }

    /// Example: `const prefix = Prefix.parse(text[0]) orelse .goto;`.
    pub fn parse(value: u8) ?Prefix {
        return switch (value) {
            '>' => .actions,
            '@' => .goto,
            '?' => .suggest,
            else => null,
        };
    }
};

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
    .{ .action = .toggle_thread_view, .label = "Toggle agent thread" },
    .{ .action = .enter_copy_mode, .label = "Enter copy mode" },
    .{ .action = .history_palette, .label = "Search command history" },
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
        const item_score = score_module(entry.label, needle) orelse continue;
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

test "the prefix byte selects the mode and text without one searches the picker" {
    try std.testing.expectEqual(Prefix.actions, prefixOf(">split"));
    try std.testing.expectEqual(Prefix.goto, prefixOf("@agent"));
    try std.testing.expectEqual(Prefix.suggest, prefixOf("?list files"));
    try std.testing.expectEqual(Prefix.goto, prefixOf(""));
    try std.testing.expectEqual(Prefix.goto, prefixOf("plain"));
    try std.testing.expectEqualStrings("split", query(">split"));
    try std.testing.expectEqualStrings("", query("?"));
    try std.testing.expectEqualStrings("plain", query("plain"));
}

test "the catalogue is bounded, stable for an empty query and filtered by fuzzy score" {
    var results: CommandResults = .{};
    collect("", &results);
    try std.testing.expectEqual(@as(u8, entries.len), results.len);
    for (results.slice(), 0..) |match, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), match.index);
    }

    collect("split", &results);
    try std.testing.expectEqual(@as(u8, 2), results.len);
    try std.testing.expectEqualStrings("Split right", entries[results.slice()[0].index].label);

    collect("sdo", &results);
    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("Split down", entries[results.slice()[0].index].label);

    collect("zzzz", &results);
    try std.testing.expectEqual(@as(u8, 0), results.len);
}

test "no catalogue entry ends the input loop or depends on a callback" {
    for (entries) |entry| {
        try std.testing.expect(entry.action != .detach);
        try std.testing.expect(entry.action != .lua_callback and entry.action != .lua_expr and entry.action != .plugin);
        try std.testing.expect(entry.label.len != 0);
    }
}
