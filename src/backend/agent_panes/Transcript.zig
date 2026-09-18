const std = @import("std");
const core = @import("telar-core");
const agent_thread = core.agent_thread;
const Transcript = @This();

value: core.AgentThreadSnapshot,
next_identity: u64 = 1,
turn_identity: u64 = 0,
ids: [agent_thread.max_items][128]u8 = undefined,
id_lengths: [agent_thread.max_items]u8 = @splat(0),
truncated_items: [agent_thread.max_items]bool = @splat(false),

/// Selects the provider turn used to scope item IDs and approval lookups.
/// Example: `try transcript.setTurn(provider_turn_id);`
pub fn setTurn(transcript: *Transcript, id: []const u8) !void {
    if (id.len > 128 or !std.unicode.utf8ValidateSlice(id) or std.mem.indexOfScalar(u8, id, 0) != null) {
        return error.InvalidProviderId;
    }

    @memcpy(transcript.value.current_turn_id[0..id.len], id);
    transcript.value.current_turn_id_len = @intCast(id.len);
}

/// Keeps the most recent items within both count and UTF-8 byte limits.
/// Example: `transcript.update(.{ .id = "item-1", .role = .assistant, .text = "Hello" });`
pub fn update(transcript: *Transcript, value: @import("ItemUpdate.zig")) void {
    var item = value;
    if (item.source_turn.len == 0 and item.id.len != 0 and (item.turn_identity orelse transcript.turn_identity) == transcript.turn_identity) {
        item.source_turn = transcript.value.currentTurnId();
    }

    if (item.id.len > 128 or !std.unicode.utf8ValidateSlice(item.id) or std.mem.indexOfScalar(u8, item.id, 0) != null or item.source_turn.len > 128 or !std.unicode.utf8ValidateSlice(item.source_turn) or std.mem.indexOfScalar(u8, item.source_turn, 0) != null) {
        transcript.value.truncated = true;
        return;
    }

    const existing = if (item.identity != 0) transcript.findIdentity(item.identity) else transcript.find(item);
    if (existing == null and transcript.next_identity == std.math.maxInt(u64)) {
        transcript.value.truncated = true;
        transcript.value.status = .failed;
        return;
    }

    var index = existing orelse transcript.append(item);
    var stored = &transcript.value.item_storage[index];
    if (stored.complete and !item.complete and stored.kind != .subagent and stored.kind != .plan) {
        return;
    }

    if (item.retain_text) {
        transcript.updateFields(index, item);
        transcript.metadata(index, item);
        return;
    }

    transcript.truncated_items[index] = item.truncated or (item.append and transcript.truncated_items[index]);
    const prior_len = if (item.append) stored.text_len else 0;
    const available = agent_thread.max_text_bytes - prior_len;
    const keep = utf8Prefix(item.text, @min(item.text.len, available));

    if (keep != item.text.len) {
        transcript.value.truncated = true;
        transcript.truncated_items[index] = true;
    }

    const additional = prior_len + keep -| stored.text_len;
    while (transcript.value.text_len + additional > agent_thread.max_text_bytes and index != 0) {
        transcript.evictFirst();
        index -= 1;
        stored = &transcript.value.item_storage[index];
    }

    if (transcript.value.text_len + additional > agent_thread.max_text_bytes) {
        transcript.value.truncated = true;
        transcript.truncated_items[index] = true;
        return;
    }

    const old_end = stored.text_offset + stored.text_len;
    const new_len = prior_len + keep;
    const new_end = stored.text_offset + new_len;
    const suffix_len = transcript.value.text_len - old_end;
    if (new_end > old_end) {
        std.mem.copyBackwards(u8, transcript.value.text_storage[new_end..][0..suffix_len], transcript.value.text_storage[old_end..][0..suffix_len]);
    } else {
        std.mem.copyForwards(u8, transcript.value.text_storage[new_end..][0..suffix_len], transcript.value.text_storage[old_end..][0..suffix_len]);
    }

    @memcpy(transcript.value.text_storage[stored.text_offset + prior_len ..][0..keep], item.text[0..keep]);
    for (transcript.value.item_storage[index + 1 .. transcript.value.item_count]) |*later| {
        later.text_offset = later.text_offset - stored.text_len + @as(u32, @intCast(new_len));
    }

    transcript.value.text_len = @intCast(transcript.value.text_len - stored.text_len + new_len);
    stored.text_len = @intCast(new_len);
    transcript.updateFields(index, item);
    transcript.value.truncated = transcript.value.truncated or item.truncated;
    transcript.metadata(index, item);
}

fn updateFields(transcript: *Transcript, index: usize, item: @import("ItemUpdate.zig")) void {
    const stored = &transcript.value.item_storage[index];
    stored.complete = item.complete;
    stored.kind = item.kind orelse stored.kind;
    stored.status = item.status orelse if (item.complete) .completed else .running;
    stored.phase = item.phase orelse stored.phase;
    stored.parent_identity = item.parent_identity orelse stored.parent_identity;
    stored.turn_identity = item.turn_identity orelse stored.turn_identity;
    stored.role = item.role;
    stored.fragment_end = !transcript.truncated_items[index];
    if (item.id.len != 0) {
        @memcpy(transcript.ids[index][0..item.id.len], item.id);
        transcript.id_lengths[index] = @intCast(item.id.len);
    }
}

/// Approval review must retain the entire referenced tool item.
/// Example: `const details = try transcript.reviewText(item_id);`
pub fn reviewText(transcript: *const Transcript, id: []const u8) !?[]const u8 {
    const index = transcript.find(.{ .id = id, .source_turn = transcript.value.currentTurnId(), .role = .tool }) orelse return null;
    if (transcript.truncated_items[index]) {
        return error.ApprovalDetailsTruncated;
    }

    return transcript.value.item_storage[index].text(&transcript.value);
}

/// Returns the stable local identity for a provider item still retained.
/// Example: `const parent = transcript.identity("dispatch-1") orelse 0;`
pub fn identity(transcript: *const Transcript, id: []const u8) ?u64 {
    const index = transcript.find(.{ .id = id, .source_turn = transcript.value.currentTurnId(), .role = .tool }) orelse return null;
    return transcript.value.item_storage[index].identity;
}

/// Example: `const row = transcript.get(child.row_identity);`
pub fn get(transcript: *Transcript, local_identity: u64) ?*core.AgentThreadItem {
    const index = transcript.findIdentity(local_identity) orelse return null;
    return &transcript.value.item_storage[index];
}

fn findIdentity(transcript: *const Transcript, local_identity: u64) ?usize {
    for (transcript.value.items(), 0..) |item, index| {
        if (item.identity == local_identity) {
            return index;
        }
    }

    return null;
}

fn metadata(transcript: *Transcript, index: usize, update_item: @import("ItemUpdate.zig")) void {
    if (update_item.title == null and update_item.detail == null and update_item.reference == null and update_item.id.len == 0 and update_item.source_turn.len == 0) {
        return;
    }

    const previous = transcript.value.metadata_storage;
    const row = &transcript.value.item_storage[index];
    const title = update_item.title orelse previous[row.title_offset..][0..row.title_len];
    const detail = update_item.detail orelse previous[row.detail_offset..][0..row.detail_len];
    const reference = update_item.reference orelse previous[row.reference_offset..][0..row.reference_len];
    const source = if (update_item.id.len != 0) update_item.id else previous[row.source_offset..][0..row.source_len];
    const source_turn = if (update_item.source_turn.len != 0) update_item.source_turn else previous[row.source_turn_offset..][0..row.source_turn_len];
    const lengths = .{
        metadataPrefix(title, agent_thread.max_item_title_bytes),
        metadataPrefix(detail, agent_thread.max_item_detail_bytes),
        if (reference.len <= agent_thread.max_item_reference_bytes and std.unicode.utf8ValidateSlice(reference) and std.mem.indexOfScalar(u8, reference, 0) == null) reference.len else 0,
        source.len,
        source_turn.len,
    };
    const old_length = @as(usize, row.title_len) + row.detail_len + row.reference_len + row.source_len + row.source_turn_len;
    const new_length = lengths[0] + lengths[1] + lengths[2] + lengths[3] + lengths[4];
    if (transcript.value.metadata_len - old_length + new_length > agent_thread.max_metadata_bytes) {
        transcript.value.truncated = true;
        return;
    }

    transcript.value.metadata_len = 0;
    for (transcript.value.item_storage[0..transcript.value.item_count], 0..) |*entry, current| {
        const strings = if (current == index) .{ title[0..lengths[0]], detail[0..lengths[1]], reference[0..lengths[2]], source, source_turn } else .{
            previous[entry.title_offset..][0..entry.title_len],
            previous[entry.detail_offset..][0..entry.detail_len],
            previous[entry.reference_offset..][0..entry.reference_len],
            previous[entry.source_offset..][0..entry.source_len],
            previous[entry.source_turn_offset..][0..entry.source_turn_len],
        };
        inline for (.{ "title", "detail", "reference", "source", "source_turn" }, 0..) |field, number| {
            @field(entry, field ++ "_offset") = transcript.value.metadata_len;
            @field(entry, field ++ "_len") = @intCast(strings[number].len);
            @memcpy(transcript.value.metadata_storage[transcript.value.metadata_len..][0..strings[number].len], strings[number]);
            transcript.value.metadata_len += @intCast(strings[number].len);
        }
    }

    transcript.value.truncated = transcript.value.truncated or lengths[0] != title.len or lengths[1] != detail.len or lengths[2] != reference.len;
}

fn compactMetadata(transcript: *Transcript) void {
    const previous = transcript.value.metadata_storage;
    transcript.value.metadata_len = 0;
    for (transcript.value.item_storage[0..transcript.value.item_count]) |*entry| {
        inline for (.{ "title", "detail", "reference", "source", "source_turn" }) |field| {
            const source = previous[@field(entry, field ++ "_offset")..][0..@field(entry, field ++ "_len")];
            @field(entry, field ++ "_offset") = transcript.value.metadata_len;
            @memcpy(transcript.value.metadata_storage[transcript.value.metadata_len..][0..source.len], source);
            transcript.value.metadata_len += @intCast(source.len);
        }
    }
}

fn find(transcript: *const Transcript, update_item: @import("ItemUpdate.zig")) ?usize {
    if (update_item.id.len == 0) {
        return null;
    }

    for (0..transcript.value.item_count) |index| {
        const item = transcript.value.item_storage[index];
        const same_turn = if (update_item.source_turn.len != 0) std.mem.eql(u8, update_item.source_turn, item.sourceTurn(&transcript.value)) else item.turn_identity == (update_item.turn_identity orelse transcript.turn_identity);
        if (same_turn and std.mem.eql(u8, update_item.id, transcript.ids[index][0..transcript.id_lengths[index]])) {
            return index;
        }
    }

    return null;
}

fn append(transcript: *Transcript, item: @import("ItemUpdate.zig")) usize {
    const reference: []const u8 = item.reference orelse "";
    const metadata_bytes = metadataPrefix(item.title orelse "", agent_thread.max_item_title_bytes) + metadataPrefix(item.detail orelse "", agent_thread.max_item_detail_bytes) + @min(reference.len, agent_thread.max_item_reference_bytes) + item.id.len + item.source_turn.len;
    while (transcript.value.item_count != 0 and transcript.value.metadata_len + metadata_bytes > agent_thread.max_metadata_bytes) {
        transcript.evictFirst();
    }

    if (transcript.value.item_count == agent_thread.max_items) {
        transcript.evictFirst();
    }

    const index = transcript.value.item_count;
    transcript.value.item_storage[index] = .{
        .role = item.role,
        .identity = transcript.next_identity,
        .turn_identity = transcript.turn_identity,
        .kind = item.kind orelse if (item.role == .system) .system else .message,
        .text_offset = transcript.value.text_len,
    };
    transcript.next_identity += 1;
    @memcpy(transcript.ids[index][0..item.id.len], item.id);
    transcript.id_lengths[index] = @intCast(item.id.len);
    transcript.truncated_items[index] = false;
    transcript.value.item_count += 1;
    return index;
}

fn evictFirst(transcript: *Transcript) void {
    const removed = transcript.value.item_storage[0].text_len;
    const count = transcript.value.item_count;
    std.mem.copyForwards(core.AgentThreadItem, transcript.value.item_storage[0 .. count - 1], transcript.value.item_storage[1..count]);
    std.mem.copyForwards([128]u8, transcript.ids[0 .. count - 1], transcript.ids[1..count]);
    std.mem.copyForwards(u8, transcript.id_lengths[0 .. count - 1], transcript.id_lengths[1..count]);
    std.mem.copyForwards(bool, transcript.truncated_items[0 .. count - 1], transcript.truncated_items[1..count]);
    transcript.value.item_count -= 1;
    transcript.value.text_len -= removed;
    std.mem.copyForwards(u8, transcript.value.text_storage[0..transcript.value.text_len], transcript.value.text_storage[removed..][0..transcript.value.text_len]);

    for (transcript.value.item_storage[0..transcript.value.item_count]) |*item| {
        item.text_offset -= removed;
    }

    transcript.compactMetadata();
    transcript.value.truncated = true;
}

fn metadataPrefix(text: []const u8, limit: usize) usize {
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    const keep = utf8Prefix(text, @min(end, limit));
    return if (std.unicode.utf8ValidateSlice(text[0..keep])) keep else 0;
}

fn utf8Prefix(text: []const u8, requested: usize) usize {
    if (requested == 0) {
        return 0;
    }

    var start = requested - 1;
    while (start != 0 and (text[start] & 0xc0) == 0x80) {
        start -= 1;
    }

    const length = std.unicode.utf8ByteSequenceLength(text[start]) catch return start;
    return if (start + length > requested) start else requested;
}

test "streamed items retain identity and authoritative completion replaces deltas" {
    var transcript: Transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 2 } };
    transcript.update(.{ .id = "a", .role = .assistant, .text = "Hello", .append = true });
    transcript.update(.{ .id = "b", .role = .tool, .text = "running" });
    transcript.update(.{ .id = "a", .role = .assistant, .text = " world", .append = true });
    try std.testing.expectEqualStrings("Hello world", transcript.value.items()[0].text(&transcript.value));
    try std.testing.expectEqualStrings("running", transcript.value.items()[1].text(&transcript.value));
    transcript.update(.{ .id = "a", .role = .assistant, .text = "Final", .complete = true });
    try std.testing.expectEqualStrings("Final", transcript.value.items()[0].text(&transcript.value));
    try std.testing.expectEqualStrings("running", transcript.value.items()[1].text(&transcript.value));
}

test "transcript scopes reused provider IDs and approval reviews to their source turn" {
    var transcript: Transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 2 }, .turn_identity = 1 };
    try transcript.setTurn("turn-a");
    transcript.update(.{ .id = "same", .role = .tool, .text = "first command", .complete = true });
    const first_identity = transcript.value.items()[0].identity;
    transcript.turn_identity = 2;
    try transcript.setTurn("turn-b");
    try std.testing.expect(transcript.identity("same") == null);
    try std.testing.expect(try transcript.reviewText("same") == null);
    transcript.update(.{ .id = "same", .role = .tool, .text = "second", .append = true });
    transcript.update(.{ .id = "same", .role = .tool, .text = " command", .append = true });
    try std.testing.expectEqual(@as(u8, 2), transcript.value.item_count);
    try std.testing.expectEqualStrings("first command", transcript.value.items()[0].text(&transcript.value));
    try std.testing.expectEqualStrings("second command", transcript.value.items()[1].text(&transcript.value));
    try std.testing.expectEqualStrings("turn-a", transcript.value.items()[0].sourceTurn(&transcript.value));
    try std.testing.expectEqualStrings("turn-b", transcript.value.items()[1].sourceTurn(&transcript.value));
    try std.testing.expect(transcript.identity("same").? != first_identity);
    try std.testing.expectEqualStrings("second command", (try transcript.reviewText("same")).?);
    transcript.evictFirst();
    try std.testing.expectEqualStrings("turn-b", transcript.value.items()[0].sourceTurn(&transcript.value));
}

test "transcript evicts oldest items to enforce count and byte limits" {
    var transcript: Transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 2 } };
    for (0..100) |_| {
        transcript.update(.{ .role = .user, .text = "x" });
    }

    try std.testing.expectEqual(@as(u8, agent_thread.max_items), transcript.value.item_count);
    try std.testing.expect(transcript.value.truncated);
    const full = [_]u8{'a'} ** agent_thread.max_text_bytes;
    transcript.update(.{ .id = "last", .role = .assistant, .text = &full });
    try std.testing.expectEqual(@as(u8, 1), transcript.value.item_count);
    try std.testing.expectEqual(@as(u32, agent_thread.max_text_bytes), transcript.value.text_len);
    transcript.update(.{ .id = "last", .role = .assistant, .text = "overflow", .append = true });
    try std.testing.expectEqual(@as(u32, agent_thread.max_text_bytes), transcript.value.text_len);
    try std.testing.expectEqualStrings("last", transcript.value.items()[0].sourceId(&transcript.value));
    try std.testing.expect(!transcript.value.items()[0].fragment_end);
}

test "transcript truncation cannot expose partial UTF8 from bounded tool formatting" {
    var transcript: Transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 2 } };
    transcript.update(.{ .id = "a", .role = .tool, .text = "output \xc3" });
    try std.testing.expectEqualStrings("output ", transcript.value.items()[0].text(&transcript.value));
    try std.testing.expect(transcript.value.truncated);
    try std.testing.expectEqual(@as(usize, 0), utf8Prefix("ñ", 1));
    try std.testing.expectEqual(@as(usize, 2), utf8Prefix("ñ", 2));
}

test "transcript typed metadata survives streaming replacement and compaction without identity reuse" {
    var transcript: Transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 2 } };
    transcript.turn_identity = 4;
    transcript.update(.{ .id = "a", .role = .tool, .kind = .command, .title = "Command", .detail = "zig test", .text = "start" });
    const identity_a = transcript.value.items()[0].identity;
    transcript.update(.{ .id = "b", .role = .tool, .kind = .subagent, .reference = "child-1", .parent_identity = identity_a, .text = "review" });
    const identity_b = transcript.value.items()[1].identity;
    transcript.update(.{ .id = "a", .role = .tool, .text = "\noutput", .append = true });
    transcript.update(.{ .id = "a", .role = .tool, .text = "failure", .status = .failed, .complete = true });
    try std.testing.expectEqual(identity_a, transcript.value.items()[0].identity);
    try std.testing.expectEqual(.command, transcript.value.items()[0].kind);
    try std.testing.expectEqual(.failed, transcript.value.items()[0].status);
    try std.testing.expectEqual(@as(u64, 4), transcript.value.items()[0].turn_identity);
    try std.testing.expectEqualStrings("zig test", transcript.value.items()[0].detail(&transcript.value));
    transcript.evictFirst();
    try std.testing.expectEqual(identity_b, transcript.value.items()[0].identity);
    try std.testing.expectEqual(identity_a, transcript.value.items()[0].parent_identity);
    try std.testing.expectEqualStrings("child-1", transcript.value.items()[0].reference(&transcript.value));
    transcript.update(.{ .id = "a", .role = .tool, .title = "New command", .text = "" });
    try std.testing.expect(transcript.value.items()[1].identity > identity_b);
    try std.testing.expectEqualStrings("child-1", transcript.value.items()[0].reference(&transcript.value));
}

test "transcript metadata is bounded valid UTF8 without NUL and reference truncation never invents identity" {
    var transcript: Transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 2 } };
    const long = [_]u8{'x'} ** 800;
    transcript.update(.{ .id = "a", .role = .tool, .title = "Safe\x00hidden", .detail = &long, .reference = &long, .text = "" });
    const item = transcript.value.items()[0];
    try std.testing.expectEqualStrings("Safe", item.title(&transcript.value));
    try std.testing.expectEqual(@as(usize, 768), item.detail(&transcript.value).len);
    try std.testing.expectEqualStrings("", item.reference(&transcript.value));
    try std.testing.expect(transcript.value.truncated);
    transcript.update(.{ .id = "a", .role = .tool, .title = "ño\xc3", .retain_text = true });
    try std.testing.expectEqualStrings("ño", transcript.value.items()[0].title(&transcript.value));
    transcript.next_identity = std.math.maxInt(u64);
    transcript.update(.{ .role = .system, .text = "Cannot allocate identity" });
    try std.testing.expectEqual(.failed, transcript.value.status);
    try std.testing.expectEqual(@as(u8, 1), transcript.value.item_count);
}

test "transcript metadata pressure evicts old rows while keeping new structured identities" {
    var transcript: Transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 2 } };
    const detail = [_]u8{'x'} ** agent_thread.max_item_detail_bytes;
    for (0..40) |_| {
        transcript.update(.{ .role = .tool, .kind = .subagent, .title = "Agent", .detail = &detail, .reference = "child-id", .text = "summary" });
    }

    try std.testing.expect(transcript.value.item_count < 40);
    try std.testing.expect(transcript.value.truncated);
    try std.testing.expect(transcript.value.metadata_len <= agent_thread.max_metadata_bytes);
    for (transcript.value.items()) |item| {
        try std.testing.expectEqualStrings("Agent", item.title(&transcript.value));
        try std.testing.expectEqualStrings("child-id", item.reference(&transcript.value));
        try std.testing.expectEqualStrings("summary", item.text(&transcript.value));
    }
}
