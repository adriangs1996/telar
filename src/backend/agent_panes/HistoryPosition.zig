const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");
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
    if (!protocol.is(protocol.field(value, "thread"), thread) or protocol.field(value, "version") != .integer or protocol.field(value, "version").integer != 2) {
        return error.InvalidHistoryCursor;
    }

    const offset = protocol.field(value, "offset");
    const after = protocol.field(value, "after");
    if (offset != .integer or offset.integer < 0 or offset.integer > std.math.maxInt(u32) or after != .bool) {
        return error.InvalidHistoryCursor;
    }

    var position: Position = .{
        .provider = try core.AgentHistoryCursor.init(protocol.string(protocol.field(value, "provider"))),
        .offset = @intCast(offset.integer),
        .after = after.bool,
    };
    try position.setSource(protocol.string(protocol.field(value, "source")), protocol.string(protocol.field(value, "turn")));
    if (position.provider.len == 0) {
        return error.InvalidHistoryCursor;
    }

    return position;
}

/// Encodes an exclusive text boundary around an inclusive provider anchor.
/// Example: `page.before = try position.encode(thread_id);`
pub fn encode(position: *const Position, thread: []const u8) !core.AgentHistoryCursor {
    var cursor: core.AgentHistoryCursor = .{};
    var writer: std.Io.Writer = .fixed(&cursor.bytes);
    std.json.Stringify.value(.{
        .version = 2,
        .thread = thread,
        .provider = position.provider.slice(),
        .source = position.source[0..position.source_len],
        .turn = position.turn[0..position.turn_len],
        .offset = position.offset,
        .after = position.after,
    }, .{}, &writer) catch return error.HistoryCursorTooLarge;
    cursor.len = @intCast(writer.end);
    return cursor;
}

/// Example: `try position.setSource(provider_item_id, provider_turn_id);`
pub fn setSource(position: *Position, source: []const u8, turn: []const u8) !void {
    if (source.len == 0 or source.len > position.source.len or !std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null or turn.len == 0 or turn.len > position.turn.len or !std.unicode.utf8ValidateSlice(turn) or std.mem.indexOfScalar(u8, turn, 0) != null) {
        return error.InvalidHistoryItem;
    }

    @memcpy(position.source[0..source.len], source);
    position.source_len = @intCast(source.len);
    @memcpy(position.turn[0..turn.len], turn);
    position.turn_len = @intCast(turn.len);
}
