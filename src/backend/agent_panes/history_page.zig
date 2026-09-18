const std = @import("std");
const core = @import("telar-core");
const ItemUpdate = @import("ItemUpdate.zig");

/// Appends one complete UTF-8 fragment without evicting another page item.
/// Example: `_ = try history_page.append(&page.snapshot, item, .{ start, end });`
pub fn append(snapshot: *core.AgentThreadSnapshot, update: ItemUpdate, range: [2]usize) !bool {
    const text = update.text[range[0]..range[1]];
    const title = prefix(update.title orelse "", core.agent_thread.max_item_title_bytes);
    const detail = prefix(update.detail orelse "", core.agent_thread.max_item_detail_bytes);
    const reference = update.reference orelse "";
    if (reference.len > core.agent_thread.max_item_reference_bytes or !validId(reference) or update.id.len == 0 or update.id.len > 128 or !validId(update.id) or update.source_turn.len > 128 or !validId(update.source_turn)) {
        return error.InvalidHistoryItem;
    }

    const metadata_bytes = title.len + detail.len + reference.len + update.id.len + update.source_turn.len;
    if (snapshot.item_count == core.agent_thread.max_items or snapshot.text_len + text.len > core.agent_thread.max_text_bytes or snapshot.metadata_len + metadata_bytes > core.agent_thread.max_metadata_bytes) {
        return false;
    }

    var hasher = std.hash.Wyhash.init(0);
    inline for (.{ snapshot.threadId(), update.source_turn, update.id }) |value| {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(value.len), .little);
        hasher.update(&length);
        hasher.update(value);
    }
    const offset: u32 = @intCast(range[0]);
    hasher.update(std.mem.asBytes(&offset));
    const identity = hasher.final() | 1;
    for (snapshot.items()) |item| {
        if (item.identity == identity) {
            return error.DuplicateHistoryItem;
        }
    }

    var item: core.AgentThreadItem = .{
        .role = update.role,
        .identity = identity,
        .turn_identity = update.turn_identity orelse 0,
        .parent_identity = update.parent_identity orelse 0,
        .kind = update.kind orelse .message,
        .status = update.status orelse .completed,
        .phase = update.phase orelse .unknown,
        .text_offset = snapshot.text_len,
        .text_len = @intCast(text.len),
        .complete = true,
        .fragment_offset = offset,
        .fragment_start = range[0] == 0,
        .fragment_end = range[1] == update.text.len,
    };
    inline for (.{ "title", "detail", "reference", "source", "source_turn" }, .{ title, detail, reference, update.id, update.source_turn }) |field, value| {
        @field(item, field ++ "_offset") = snapshot.metadata_len;
        @field(item, field ++ "_len") = @intCast(value.len);
        @memcpy(snapshot.metadata_storage[snapshot.metadata_len..][0..value.len], value);
        snapshot.metadata_len += @intCast(value.len);
    }

    @memcpy(snapshot.text_storage[snapshot.text_len..][0..text.len], text);
    snapshot.text_len += @intCast(text.len);
    snapshot.item_storage[snapshot.item_count] = item;
    snapshot.item_count += 1;
    return true;
}

/// Example: `const boundary = history_page.prefix(text, maximum).len;`
pub fn prefix(text: []const u8, maximum: usize) []const u8 {
    var end = @min(text.len, maximum);
    while (end < text.len and end != 0 and text[end] & 0xc0 == 0x80) {
        end -= 1;
    }

    const result = text[0..end];
    const clean_end = std.mem.indexOfScalar(u8, result, 0) orelse result.len;
    return result[0..clean_end];
}

fn validId(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text) and std.mem.indexOfScalar(u8, text, 0) == null;
}
