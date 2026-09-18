const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");
const Position = @import("HistoryPosition.zig");
const page = @import("history_page.zig");
const Entry = @import("HistoricalItem.zig");
const LegacyHistory = @This();

entries: [4096]Entry = undefined,
count: usize = 0,
body: []u8,
query: core.QueryAgentHistory,

/// Indexes one bounded legacy response while its JSON storage remains alive.
/// Example: `try history.load(thread);`
pub fn load(history: *LegacyHistory, thread: std.json.Value) !void {
    const turns = protocol.field(thread, "turns");
    if (turns != .array or turns.array.items.len > history.entries.len) {
        return error.InvalidHistoryResponse;
    }

    for (turns.array.items) |turn| {
        const items = protocol.field(turn, "items");
        if (items != .array or items.array.items.len > history.entries.len - history.count) {
            return error.HistoryScanLimit;
        }

        for (items.array.items) |item| {
            history.entries[history.count] = .{ .value = item, .turn = protocol.string(protocol.field(turn, "id")) };
            history.count += 1;
        }
    }
}

/// Uses exclusive item/text boundaries in both directions without duplicating fragments.
/// Example: `try history.fill(output, thread_id);`
pub fn fill(history: *LegacyHistory, output: *core.AgentHistoryPage, thread_id: []const u8) !void {
    const query = history.query;
    const older = query.direction == .older;
    var boundary: ?Position = if (query.cursor.len != 0) try Position.decode(query.cursor, thread_id) else null;
    var index: i64 = if (older) @as(i64, @intCast(history.count)) - 1 else 0;
    if (boundary) |position| {
        if (!std.mem.startsWith(u8, position.provider.slice(), "legacy:")) {
            return error.InvalidHistoryCursor;
        }

        index = std.fmt.parseInt(i64, position.provider.slice()[7..], 10) catch return error.InvalidHistoryCursor;
        if (index < 0 or index >= history.count) {
            return error.HistoryAnchorUnavailable;
        }
    } else if (query.anchor.len != 0) {
        const anchor = for (history.entries[0..history.count], 0..) |entry, ordinal| {
            if (protocol.is(protocol.field(entry.value, "id"), query.anchor) and std.mem.eql(u8, entry.turn, query.anchor_turn)) {
                break ordinal;
            }
        } else return error.HistoryAnchorUnavailable;
        index = @as(i64, @intCast(anchor)) + (if (older) @as(i64, -1) else 1);
    }

    while (index >= 0 and index < history.count) : (index += if (older) @as(i64, -1) else 1) {
        const entry = history.entries[@intCast(index)];
        var normalizer: @import("ItemNormalizer.zig") = .{ .body_buffer = history.body, .include_history_details = true };
        var update = try @import("historical_item.zig").normalize(&normalizer, entry.value);
        if (update.truncated or !std.unicode.utf8ValidateSlice(update.text)) {
            return error.HistoryItemNotRepresentable;
        }

        update.source_turn = entry.turn;
        update.turn_identity = std.hash.Wyhash.hash(0, entry.turn) | 1;
        var start: usize = 0;
        var end = update.text.len;
        if (boundary) |position| {
            if (!std.mem.eql(u8, update.id, position.source[0..position.source_len]) or !std.mem.eql(u8, entry.turn, position.turn[0..position.turn_len]) or position.offset > end or !std.unicode.utf8ValidateSlice(update.text[0..position.offset])) {
                return error.HistoryAnchorUnavailable;
            }

            if (older) {
                end = position.offset;
            } else {
                start = position.offset;
            }
            boundary = null;
            if (start == end and (update.text.len != 0 or position.after == !older)) {
                continue;
            }
        }

        const available = core.agent_thread.max_text_bytes - output.snapshot.text_len;
        if (end - start > available and output.snapshot.item_count != 0) {
            break;
        }
        if (older) {
            start = end -| available;
            while (start < end and update.text[start] & 0xc0 == 0x80) {
                start += 1;
            }
        } else {
            end = start + page.prefix(update.text[start..end], available).len;
        }
        if (!try page.append(&output.snapshot, update, .{ start, end })) {
            break;
        }

        var storage: [32]u8 = undefined;
        var before: Position = .{ .provider = try core.AgentHistoryCursor.init(try std.fmt.bufPrint(&storage, "legacy:{d}", .{index})), .offset = @intCast(start) };
        try before.setSource(update.id, entry.turn);
        var after = before;
        after.offset = @intCast(end);
        after.after = true;
        if (output.snapshot.item_count == 1 or older) {
            output.before = try before.encode(thread_id);
            output.has_before = index > 0 or start > 0;
        }
        if (output.snapshot.item_count == 1 or !older) {
            output.after = try after.encode(thread_id);
            output.has_after = index + 1 < history.count or end < update.text.len;
        }
        if ((older and start != 0) or (!older and end != update.text.len) or output.snapshot.item_count == core.agent_thread.max_items or output.snapshot.text_len == core.agent_thread.max_text_bytes) {
            break;
        }
    }

    if (older) {
        std.mem.reverse(core.AgentThreadItem, output.snapshot.item_storage[0..output.snapshot.item_count]);
    }
}

test "legacy history pages preserve ordering and exclusive boundaries across both directions" {
    const source = comptime blk: {
        @setEvalBranchQuota(10000);
        var text: []const u8 = "{\"turns\":[{\"id\":\"turn-1\",\"items\":[";
        for (0..70) |index| {
            text = text ++ (if (index == 0) "" else ",") ++ std.fmt.comptimePrint("{{\"id\":\"item-{d}\",\"type\":\"agentMessage\",\"text\":\"Message {d}\"}}", .{ index, index });
        }
        break :blk text ++ "]}]}";
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const history = try std.testing.allocator.create(LegacyHistory);
    defer std.testing.allocator.destroy(history);
    var body: [4096]u8 = undefined;
    const query: core.QueryAgentHistory = .{ .request_id = @enumFromInt(1), .pane_id = @enumFromInt(2), .pane_generation = 3, .view_generation = 4 };
    history.* = .{ .body = &body, .query = query };
    try history.load(parsed.value);
    var newest: core.AgentHistoryPage = .{ .request_id = query.request_id, .view_generation = query.view_generation, .snapshot = .{ .pane_id = query.pane_id, .pane_generation = query.pane_generation } };
    try history.fill(&newest, "previous-thread");
    try std.testing.expectEqual(64, newest.snapshot.item_count);
    try std.testing.expectEqualStrings("Message 6", newest.snapshot.items()[0].text(&newest.snapshot));
    try std.testing.expectEqualStrings("Message 69", newest.snapshot.items()[63].text(&newest.snapshot));
    try std.testing.expect(newest.has_before and !newest.has_after);
    history.query.cursor = newest.before.slice();
    var older: core.AgentHistoryPage = .{ .request_id = query.request_id, .view_generation = query.view_generation, .snapshot = .{ .pane_id = query.pane_id, .pane_generation = query.pane_generation } };
    try history.fill(&older, "previous-thread");
    try std.testing.expectEqual(6, older.snapshot.item_count);
    try std.testing.expectEqualStrings("Message 0", older.snapshot.items()[0].text(&older.snapshot));
    try std.testing.expectEqualStrings("Message 5", older.snapshot.items()[5].text(&older.snapshot));
    try std.testing.expect(!older.has_before and older.has_after);
    history.query.cursor = older.after.slice();
    history.query.direction = .newer;
    var forward: core.AgentHistoryPage = .{ .request_id = query.request_id, .view_generation = query.view_generation, .snapshot = .{ .pane_id = query.pane_id, .pane_generation = query.pane_generation } };
    try history.fill(&forward, "previous-thread");
    try std.testing.expectEqual(64, forward.snapshot.item_count);
    try std.testing.expectEqualStrings("Message 6", forward.snapshot.items()[0].text(&forward.snapshot));
    try std.testing.expectError(error.InvalidHistoryCursor, history.fill(&forward, "other-thread"));
}
