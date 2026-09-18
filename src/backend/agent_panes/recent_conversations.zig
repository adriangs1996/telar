const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");

/// Publishes one bounded provider listing after validating its scope and IDs.
/// Example: `try recent_conversations.load(snapshot, result, cwd);`
pub fn load(snapshot: *core.AgentThreadSnapshot, result: std.json.Value, cwd: []const u8) !void {
    const data = protocol.field(result, "data");
    if (data != .array or data.array.items.len > core.RecentConversations.capacity) {
        return error.InvalidConversationList;
    }

    var recent: core.RecentConversations = .{ .phase = .ready, .has_more = protocol.string(protocol.field(result, "nextCursor")).len != 0 };
    for (data.array.items) |entry| {
        const id = protocol.string(protocol.field(entry, "id"));
        if (!protocol.is(protocol.field(entry, "cwd"), cwd)) {
            return error.InvalidConversationDirectory;
        }
        if (std.mem.eql(u8, id, snapshot.threadId()) or protocol.field(entry, "parentThreadId") == .string or protocol.is(protocol.field(protocol.field(entry, "status"), "type"), "active")) {
            continue;
        }

        const name = protocol.string(protocol.field(entry, "name"));
        const raw = if (name.len != 0) name else protocol.string(protocol.field(entry, "preview"));
        const prefix = @import("history_page.zig").prefix(raw, 160);
        var title: [160]u8 = undefined;
        for (prefix, 0..) |byte, index| {
            title[index] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        }

        try recent.append(try core.RecentConversation.init(id, title[0..prefix.len]));
    }

    snapshot.recent = recent;
}
