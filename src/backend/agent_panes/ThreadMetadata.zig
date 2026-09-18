//! Owned provider metadata published with the matching transcript snapshot.
const std = @import("std");
const core = @import("telar-core");
const Metadata = @This();

revision: u64 = 0,
buffer: [core.max_agent_session_title_bytes]u8 = undefined,
len: u8 = 0,

/// Accepts an explicit provider name or clear without failing its conversation.
/// Invalid values and duplicate normalized names leave the revision unchanged.
/// Example: `metadata.applyName(.{ .string = "Review input routing" });`
pub fn applyName(metadata: *Metadata, value: std.json.Value) void {
    const raw = switch (value) {
        .null => "",
        .string => |name| name,
        else => return,
    };
    if (!std.unicode.utf8ValidateSlice(raw)) {
        return;
    }

    for (raw) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return;
        }
    }

    var buffer: [core.max_agent_session_title_bytes]u8 = undefined;
    const name = core.truncateSessionTitle(&buffer, raw);
    if (name.len != 0) {
        core.validateSessionTitle(name) catch return;
    }

    if (metadata.revision != 0 and std.mem.eql(u8, metadata.buffer[0..metadata.len], name)) {
        return;
    }

    const revision = std.math.add(u64, metadata.revision, 1) catch return;
    @memcpy(metadata.buffer[0..name.len], name);
    metadata.len = @intCast(name.len);
    metadata.revision = revision;
}

/// Distinguishes an unobserved name from an explicitly cleared provider name.
/// Example: `if (metadata.nameSlice()) |name| publishAgentTitle(name);`
pub fn nameSlice(metadata: *const Metadata) ?[]const u8 {
    return if (metadata.revision == 0) null else metadata.buffer[0..metadata.len];
}

test "provider thread metadata owns names and distinguishes missing from clear" {
    var metadata: Metadata = .{};
    try std.testing.expect(metadata.nameSlice() == null);
    metadata.applyName(.null);
    try std.testing.expectEqual(1, metadata.revision);
    try std.testing.expectEqualStrings("", metadata.nameSlice().?);
    metadata.applyName(.{ .string = "" });
    try std.testing.expectEqual(1, metadata.revision);
    var source = "Review title".*;
    metadata.applyName(.{ .string = &source });
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("Review title", metadata.nameSlice().?);
    try std.testing.expectEqual(2, metadata.revision);
    metadata.applyName(.{ .string = "Review title" });
    try std.testing.expectEqual(2, metadata.revision);
    metadata.applyName(.null);
    try std.testing.expectEqual(3, metadata.revision);
    try std.testing.expectEqualStrings("", metadata.nameSlice().?);
}

test "provider thread metadata truncates UTF8 and ignores invalid names without wrapping revisions" {
    var metadata: Metadata = .{};
    const long = "a" ** 95 ++ "🙂tail";
    metadata.applyName(.{ .string = long });
    try std.testing.expectEqualStrings("a" ** 95, metadata.nameSlice().?);
    try std.testing.expectEqual(1, metadata.revision);
    metadata.applyName(.{ .string = "a" ** 95 ++ "🙂different suffix" });
    try std.testing.expectEqual(1, metadata.revision);
    for ([_][]const u8{ "bad\x00title", "bad\x1btitle", "bad\ntitle", "bad\xfftitle", "a" ** 100 ++ "\x00" }) |name| {
        metadata.applyName(.{ .string = name });
        try std.testing.expectEqual(1, metadata.revision);
        try std.testing.expectEqualStrings("a" ** 95, metadata.nameSlice().?);
    }

    metadata.applyName(.{ .integer = 17 });
    try std.testing.expectEqual(1, metadata.revision);
    metadata.revision = std.math.maxInt(u64);
    metadata.applyName(.{ .string = "new" });
    try std.testing.expectEqual(std.math.maxInt(u64), metadata.revision);
    try std.testing.expectEqualStrings("a" ** 95, metadata.nameSlice().?);
}
