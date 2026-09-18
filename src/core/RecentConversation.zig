const std = @import("std");

id: [128]u8 = @splat(0),
id_len: u8 = 0,
title: [160]u8 = @splat(0),
title_len: u8 = 0,

/// Example: `const entry = try RecentConversation.init(id, title);`
pub fn init(id: []const u8, title: []const u8) !@This() {
    try @import("schema/messages/agent.zig").validateSessionReference(id);
    if (title.len > 160 or !std.unicode.utf8ValidateSlice(title)) {
        return error.InvalidConversation;
    }

    for (title) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidConversation;
        }
    }

    var value: @This() = .{ .id_len = @intCast(id.len), .title_len = @intCast(title.len) };
    @memcpy(value.id[0..id.len], id);
    @memcpy(value.title[0..title.len], title);
    return value;
}

/// Example: `resume(entry.idSlice());`
pub fn idSlice(value: *const @This()) []const u8 {
    return value.id[0..value.id_len];
}

/// Example: `draw(entry.titleSlice());`
pub fn titleSlice(value: *const @This()) []const u8 {
    return if (value.title_len == 0) value.idSlice() else value.title[0..value.title_len];
}
