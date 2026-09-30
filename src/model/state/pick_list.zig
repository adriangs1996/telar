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
/// when it is longer than a label may be.
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

        try items.append(.{
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

test "options match by label or detail, best first and list order on ties" {
    var items: PickItems = .{};
    try items.append(.{ .label = "claude-sonnet-5-5", .detail = "anthropic" });
    try items.append(.{ .label = "gpt-6-sol", .detail = "openai-codex" });
    try items.append(.{ .label = "claude-opus-5-5", .detail = "anthropic" });

    var results: PickResults = .{};
    collect(&items, "", &results);
    try std.testing.expectEqual(@as(u16, 3), results.len);
    for (results.slice(), 0..) |match, position| {
        try std.testing.expectEqual(@as(u16, @intCast(position)), match.index);
    }

    collect(&items, "opus", &results);
    try std.testing.expectEqual(@as(u16, 1), results.len);
    try std.testing.expectEqual(@as(u16, 2), results.slice()[0].index);

    collect(&items, "codex", &results);
    try std.testing.expectEqual(@as(u16, 1), results.slice()[0].index);

    try std.testing.expectEqual(@as(?u16, 2), chosen(&items, "claude", 1));
    try std.testing.expectEqual(@as(?u16, 2), chosen(&items, "claude", 9));
    try std.testing.expectEqual(@as(?u16, null), chosen(&items, "zzz", 0));
}

test "each nonempty trimmed line becomes an option and a surplus fails" {
    var items: PickItems = .{};
    try readLines(&items, "  low\r\n\nmedium\t\nhigh\tfast");
    try std.testing.expectEqual(@as(u16, 3), items.count);
    try std.testing.expectEqualStrings("low", items.label(0));
    try std.testing.expectEqualStrings("medium", items.value(1));
    try std.testing.expectEqualStrings("high fast", items.label(2));
    try std.testing.expectEqualStrings("high\tfast", items.value(2));

    const long = "é" ** 100;
    try readLines(&items, long);
    try std.testing.expectEqualStrings(long, items.value(0));
    try std.testing.expectEqualStrings("é" ** (PickItems.max_label_bytes / 2), items.label(0));
    try std.testing.expectError(error.PickItemTooLong, readLines(&items, "x" ** (PickItems.max_value_bytes + 1)));

    var text: [2 * (PickItems.max_items + 1)]u8 = undefined;
    for (0..PickItems.max_items + 1) |line| {
        text[2 * line] = 'x';
        text[2 * line + 1] = '\n';
    }

    try std.testing.expectError(error.TooManyPickItems, readLines(&items, &text));
}
