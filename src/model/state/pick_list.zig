//! Pick list matching: the open list's options filtered by the palette
//! query, best match first and list order among equal scores. The palette
//! draws these rows and the submission takes the chosen one, so both read
//! the same list.
const core = @import("telar-core");
const std = @import("std");
const PickItems = @import("../bars/PickItems.zig");
const PickResults = @import("PickResults.zig");
const PickMatch = @import("PickMatch.zig");
const bar_text = @import("../bars/bar_text.zig");

/// Fills `results` with every option whose label or detail matches `query`.
/// Sorting is O(n log n), so a list of a thousand options stays cheap to
/// redraw on each keystroke.
///
/// ```zig
/// var results: PickResults = .{};
/// pick_list.collect(&model.pick_list.items, prompt.field.text(), &results);
/// ```
pub fn collect(items: *const PickItems, query: []const u8, results: *PickResults) void {
    results.len = 0;
    for (0..items.count) |position| {
        const index: u16 = @intCast(position);
        const item_score = core.score(items.label(index), query) orelse core.score(items.detail(index), query) orelse continue;
        results.matches[results.len] = .{
            .index = index,
            .score = item_score,
        };
        results.len += 1;
    }

    std.mem.sort(PickMatch, results.matches[0..results.len], {}, better);
}

/// The option the selection names among the matches for `query`, or null
/// when nothing matches.
///
/// ```zig
/// const index = pick_list.chosen(&model.pick_list.items, query, selection) orelse return;
/// ```
pub fn chosen(items: *const PickItems, query: []const u8, selection: u16) ?u16 {
    var results: PickResults = .{};
    collect(items, query, &results);
    if (results.len == 0) {
        return null;
    }

    return results.matches[@min(selection, results.len - 1)].index;
}

/// Replaces `items` with one option per nonempty line of a list command's
/// output, trimmed of surrounding blanks. The line is the value as printed,
/// tabs included; its label shows tabs as spaces and is cut at a character
/// when it is longer than a label may be. Options past the list's limits
/// are left out and `items.reaches` names the limits passed.
///
/// ```zig
/// try pick_list.readLines(&model.pick_list.items, output);
/// ```
pub fn readLines(items: *PickItems, text: []const u8) !void {
    items.clear();
    var label: [PickItems.max_label_bytes]u8 = undefined;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const option = std.mem.trim(u8, line, " \t\r");
        if (option.len == 0) {
            continue;
        }

        const shown = bar_text.prefix(option, label.len);
        for (shown, 0..) |byte, index| {
            label[index] = if (byte == '\t') ' ' else byte;
        }

        try items.keep(.{
            .label = label[0..shown.len],
            .value = option,
        });
    }
}

fn better(_: void, left: PickMatch, right: PickMatch) bool {
    if (left.score != right.score) {
        return left.score > right.score;
    }

    return left.index < right.index;
}
