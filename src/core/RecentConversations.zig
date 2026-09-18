const std = @import("std");
const Entry = @import("RecentConversation.zig");

pub const capacity = 16;
pub const Phase = enum(u8) { loading, ready, failed };

phase: Phase = .loading,
entries: [capacity]Entry = @splat(.{}),
count: u8 = 0,
has_more: bool = false,

/// Rejects duplicate references before publishing a provider catalog.
/// Example: `try recent.append(entry);`
pub fn append(recent: *@This(), entry: Entry) !void {
    if (recent.count == capacity) {
        return error.TooManyConversations;
    }

    for (recent.entries[0..recent.count]) |*previous| {
        if (std.mem.eql(u8, previous.idSlice(), entry.idSlice())) {
            return error.DuplicateConversation;
        }
    }

    recent.entries[recent.count] = entry;
    recent.count += 1;
}

/// Example: `try recent.encode(encoder);`
pub fn encode(recent: *const @This(), encoder: *@import("schema/Encoder.zig")) !void {
    if (recent.count > capacity) {
        return error.TooManyConversations;
    }

    try encoder.writeByte(@intFromEnum(recent.phase));
    try encoder.writeByte(@intFromBool(recent.has_more));
    try encoder.writeByte(recent.count);
    for (recent.entries[0..recent.count]) |*entry| {
        if (entry.id_len > entry.id.len or entry.title_len > entry.title.len) {
            return error.InvalidConversation;
        }

        _ = try Entry.init(entry.idSlice(), entry.title[0..entry.title_len]);
        try encoder.writeSized16(entry.idSlice());
        try encoder.writeSized16(entry.title[0..entry.title_len]);
    }
}

/// Example: `const recent = try RecentConversations.decode(decoder);`
pub fn decode(decoder: *@import("schema/Decoder.zig")) !@This() {
    var recent: @This() = .{
        .phase = std.enums.fromInt(Phase, try decoder.readByte()) orelse return error.InvalidConversation,
        .has_more = try decoder.readBool(),
    };
    const count = try decoder.readByte();
    if (count > capacity) {
        return error.TooManyConversations;
    }

    for (0..count) |_| {
        const id = try decoder.readSized16();
        const title = try decoder.readSized16();
        try recent.append(try Entry.init(id, title));
    }

    return recent;
}
