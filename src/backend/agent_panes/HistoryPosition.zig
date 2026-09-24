const jsonl = @import("jsonl");
const std = @import("std");
const core = @import("telar-core");
const Position = @This();

provider: core.AgentHistoryCursor = .{},
source: [128]u8 = undefined,
source_len: u8 = 0,
turn: [128]u8 = undefined,
turn_len: u8 = 0,
offset: u32 = 0,
after: bool = false,

/// Decodes only Telar's envelope; the provider cursor remains opaque.
/// Example: `const position = try HistoryPosition.decode(query.cursor, thread_id);`
pub fn decode(bytes: []const u8, thread: []const u8) !Position {
    var storage: [16 * 1024]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&storage);
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator.allocator(), bytes, .{}) catch return error.InvalidHistoryCursor;
    if (!jsonl.is(jsonl.field(value, "thread"), thread) or jsonl.field(value, "version") != .integer or jsonl.field(value, "version").integer != 2) {
        return error.InvalidHistoryCursor;
    }

    const offset = jsonl.field(value, "offset");
    const after = jsonl.field(value, "after");
    if (offset != .integer or offset.integer < 0 or offset.integer > std.math.maxInt(u32) or after != .bool) {
        return error.InvalidHistoryCursor;
    }

    var position: Position = .{
        .provider = try core.AgentHistoryCursor.init(jsonl.string(jsonl.field(value, "provider"))),
        .offset = @intCast(offset.integer),
        .after = after.bool,
    };
    try position.setSource(jsonl.string(jsonl.field(value, "source")), jsonl.string(jsonl.field(value, "turn")));
    if (position.provider.len == 0) {
        return error.InvalidHistoryCursor;
    }

    return position;
}

/// Encodes an exclusive text boundary around an inclusive provider anchor.
/// Example: `page.before = try position.encode(thread_id);`
pub fn encode(self: *const Position, thread: []const u8) !core.AgentHistoryCursor {
    var cursor: core.AgentHistoryCursor = .{};
    var writer: std.Io.Writer = .fixed(&cursor.bytes);
    std.json.Stringify.value(.{
        .version = 2,
        .thread = thread,
        .provider = self.provider.slice(),
        .source = self.source[0..self.source_len],
        .turn = self.turn[0..self.turn_len],
        .offset = self.offset,
        .after = self.after,
    }, .{}, &writer) catch return error.HistoryCursorTooLarge;
    cursor.len = @intCast(writer.end);
    return cursor;
}

/// Example: `try position.setSource(provider_item_id, provider_turn_id);`
pub fn setSource(self: *Position, source: []const u8, turn: []const u8) !void {
    if (source.len == 0 or source.len > self.source.len or !std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null or turn.len == 0 or turn.len > self.turn.len or !std.unicode.utf8ValidateSlice(turn) or std.mem.indexOfScalar(u8, turn, 0) != null) {
        return error.InvalidHistoryItem;
    }

    @memcpy(self.source[0..source.len], source);
    self.source_len = @intCast(source.len);
    @memcpy(self.turn[0..turn.len], turn);
    self.turn_len = @intCast(turn.len);
}
