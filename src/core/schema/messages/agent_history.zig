//! History pages are targeted request replies, independent of live revisions.
const std = @import("std");
const Encoder = @import("../Encoder.zig");
const Decoder = @import("../Decoder.zig");
const codec = @import("../codec.zig");
const id = @import("../id.zig");
const tags = @import("tags.zig");
const history = @import("../../agent_history.zig");
const Query = @import("QueryAgentHistory.zig");
const Page = @import("../../AgentHistoryPage.zig");
const View = @import("AgentHistoryPageView.zig");
const Cursor = @import("../../AgentHistoryCursor.zig");
const thread = @import("agent_thread.zig");

/// Example: `const bytes = try encodeQueryAgentHistory(buffer, request);`
pub fn encodeQueryAgentHistory(buffer: []u8, query: Query) ![]const u8 {
    try validateQuery(query);
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.query_agent_history));
    try encoder.writeInt(u64, id.raw(query.request_id));
    try encoder.writeInt(u64, id.raw(query.pane_id));
    try encoder.writeInt(u64, query.pane_generation);
    try encoder.writeInt(u64, query.view_generation);
    try encoder.writeByte(@intFromEnum(query.direction));
    try encoder.writeSized16(query.cursor);
    try encoder.writeSized16(query.anchor);
    try encoder.writeSized16(query.anchor_turn);
    return encoder.finish();
}

/// Example: `const query = try decodeQueryAgentHistory(&decoder);`
pub fn decodeQueryAgentHistory(decoder: *Decoder) !Query {
    const query: Query = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .view_generation = try decoder.readInt(u64),
        .direction = std.enums.fromInt(history.Direction, try decoder.readByte()) orelse return error.InvalidAgentHistoryDirection,
        .cursor = try decoder.readSized16(),
        .anchor = try decoder.readSized16(),
        .anchor_turn = try decoder.readSized16(),
    };
    try validateQuery(query);
    return query;
}

/// Example: `const bytes = try encodeAgentHistoryPage(buffer, page);`
pub fn encodeAgentHistoryPage(buffer: []u8, page: *const Page) ![]const u8 {
    try codec.validateRequestId(page.request_id);
    if (page.view_generation == 0 or page.before.len > history.max_cursor_bytes or page.after.len > history.max_cursor_bytes) {
        return error.InvalidAgentHistoryPage;
    }

    try validatePositions(page.before.slice(), page.after.slice());
    if ((page.has_before and page.before.len == 0) or (page.has_after and page.after.len == 0)) {
        return error.InvalidAgentHistoryPage;
    }

    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.agent_history_page));
    try encoder.writeInt(u64, id.raw(page.request_id));
    try encoder.writeInt(u64, page.view_generation);
    try encoder.writeByte(@intFromBool(page.has_before));
    try encoder.writeByte(@intFromBool(page.has_after));
    try encoder.writeSized16(page.before.slice());
    try encoder.writeSized16(page.after.slice());
    try thread.encodeSnapshotBody(&encoder, &page.snapshot);
    return encoder.finish();
}

/// Example: `const page = try decodeAgentHistoryPage(&decoder);`
pub fn decodeAgentHistoryPage(decoder: *Decoder) !View {
    const request_id = try id.request(try decoder.readInt(u64));
    const view_generation = try decoder.readInt(u64);
    const has_before = try decoder.readBool();
    const has_after = try decoder.readBool();
    const before = try decoder.readSized16();
    const after = try decoder.readSized16();
    try codec.validateRequestId(request_id);
    try validatePositions(before, after);
    if (view_generation == 0 or (has_before and before.len == 0) or (has_after and after.len == 0)) {
        return error.InvalidAgentHistoryPage;
    }

    return .{
        .request_id = request_id,
        .view_generation = view_generation,
        .snapshot = try thread.decodeAgentThreadSnapshot(decoder),
        .before = before,
        .after = after,
        .has_before = has_before,
        .has_after = has_after,
    };
}

fn validateQuery(query: Query) !void {
    try codec.validateRequestId(query.request_id);
    try codec.validatePaneId(query.pane_id);
    if (query.pane_generation == 0 or query.view_generation == 0 or query.anchor.len > @import("../../agent_thread.zig").max_item_source_bytes or (query.cursor.len != 0 and query.anchor.len != 0)) {
        return error.InvalidAgentHistoryQuery;
    }

    if (query.anchor_turn.len > @import("../../agent_thread.zig").max_item_source_turn_bytes or (query.anchor.len == 0) != (query.anchor_turn.len == 0)) {
        return error.InvalidAgentHistoryQuery;
    }

    if (!std.unicode.utf8ValidateSlice(query.anchor_turn) or std.mem.indexOfScalar(u8, query.anchor_turn, 0) != null) {
        return error.InvalidAgentHistoryQuery;
    }

    _ = try Cursor.init(query.cursor);
    if (!std.unicode.utf8ValidateSlice(query.anchor) or std.mem.indexOfScalar(u8, query.anchor, 0) != null) {
        return error.InvalidAgentHistoryQuery;
    }
}

fn validatePositions(before: []const u8, after: []const u8) !void {
    _ = try Cursor.init(before);
    _ = try Cursor.init(after);
}
