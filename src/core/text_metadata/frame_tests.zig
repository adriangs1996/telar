const std = @import("std");
const Builder = @import("Builder.zig");
const View = @import("View.zig");
const limits = @import("limits.zig");
const frame = @import("../schema/frame_support.zig");
const pane = @import("../schema/messages/pane.zig");
const messages = @import("../schema/messages/messages.zig");
const Cell = @import("../ui/Cell.zig");
const Span = @import("../schema/Span.zig");

const metadata_length_offset = 1 + frame.body_header_size - @sizeOf(u32);
const metadata_offset = 1 + frame.body_header_size;

fn snapshot(buffer: []u8, metadata: ?View) ![]const u8 {
    const cells = [_]Cell{.{}} ** 8;
    const spans = [_]Span{.{ .start = 0, .cells = &cells }};
    return pane.encodePaneFrame(buffer, .{
        .pane_id = @enumFromInt(4),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 4,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &spans,
        .text_metadata = metadata,
    });
}

fn patch(buffer: []u8, metadata: ?View) ![]const u8 {
    return pane.encodePaneFrame(buffer, .{
        .pane_id = @enumFromInt(4),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 4,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &.{},
        .text_metadata = metadata,
    });
}

test "frame wire distinguishes unchanged empty complete and omitted text metadata" {
    var buffer: [1024]u8 = undefined;
    var scratch: [limits.capacity(2)]u8 = undefined;
    var builder = Builder.init(&scratch, 2);
    const full = (try messages.decodeServer(try snapshot(&buffer, null))).pane_frame;
    try std.testing.expect(full.isSnapshot());
    try std.testing.expect(full.text_metadata != null);
    try std.testing.expectEqual(limits.Status.complete, full.text_metadata.?.status);
    try std.testing.expectEqual(@as(usize, 2), full.text_metadata.?.rows.len);
    try std.testing.expectEqual(@as(u16, 0), full.text_metadata.?.link_count);

    const unchanged_payload = try patch(&buffer, null);
    const unchanged = (try messages.decodeServer(unchanged_payload)).pane_frame;
    try std.testing.expectEqual(@as(usize, 1 + frame.body_header_size), unchanged_payload.len);
    try std.testing.expect(!unchanged.isSnapshot());
    try std.testing.expect(unchanged.text_metadata == null);
    var spans = unchanged.spans();
    try std.testing.expect((try spans.next()) == null);

    builder.setRow(0, .{ .wrap = true });
    builder.setRow(1, .{ .continuation = true });
    for ([_]limits.Status{ .complete, .omitted }) |status| {
        const replacement = builder.finish(status);
        const payload = try patch(&buffer, replacement);
        const decoded = (try messages.decodeServer(payload)).pane_frame;
        try std.testing.expect(decoded.text_metadata != null);
        try std.testing.expectEqual(status, decoded.text_metadata.?.status);
        try std.testing.expect(decoded.text_metadata.?.rows[0].wrap);
        try std.testing.expect(decoded.text_metadata.?.rows[1].continuation);
        try std.testing.expectEqual(@as(u16, 0), decoded.text_metadata.?.link_count);
    }
}

test "frame metadata round trips arbitrary URI bytes without retaining builder storage" {
    var buffer: [1024]u8 = undefined;
    var scratch: [limits.capacity(2)]u8 = undefined;
    var builder = Builder.init(&scratch, 2);
    const uri = "custom://host/\xff\x00path";
    const identity = try builder.addLink(uri);
    builder.setRow(1, .{ .hyperlinks = true });
    try builder.addRun(.{ .start = 5, .len = 2, .link_index = identity });
    const original = builder.finish(.complete);
    const payload = try snapshot(&buffer, original);
    const decoded = (try messages.decodeServer(payload)).pane_frame;
    @memset(&scratch, 0);
    const metadata = decoded.text_metadata.?;
    try std.testing.expectEqualStrings(uri, metadata.link(identity).?);
    try std.testing.expectEqual(@as(u16, 0), metadata.at(5).?.link_index);
    try std.testing.expectEqual(@as(u32, 2), metadata.at(6).?.len);
    try std.testing.expect(metadata.at(7) == null);
    try std.testing.expect(@intFromPtr(metadata.encoded.ptr) >= @intFromPtr(payload.ptr));
    try std.testing.expect(@intFromPtr(metadata.encoded.ptr) + metadata.encoded.len <= @intFromPtr(payload.ptr) + payload.len);
}

test "frame decoding rejects missing oversized or corrupt metadata before returning any cell spans" {
    var buffer: [1024]u8 = undefined;
    var scratch: [limits.capacity(2)]u8 = undefined;
    var builder = Builder.init(&scratch, 2);
    const identity = try builder.addLink("https://example.test");
    try builder.addRun(.{ .start = 1, .len = 2, .link_index = identity });
    const payload = try snapshot(&buffer, builder.finish(.complete));
    var malformed = buffer;
    std.mem.writeInt(u32, malformed[metadata_length_offset..][0..4], 0, .little);
    try std.testing.expectError(error.MissingSnapshotMetadata, messages.decodeServer(malformed[0..payload.len]));

    malformed = buffer;
    std.mem.writeInt(u32, malformed[metadata_length_offset..][0..4], @intCast(limits.capacity(2) + 1), .little);
    try std.testing.expectError(error.TextMetadataTooLarge, messages.decodeServer(malformed[0..metadata_offset]));

    malformed = buffer;
    malformed[metadata_offset + limits.header_size] = 0xf0;
    try std.testing.expectError(error.InvalidTextMetadata, messages.decodeServer(malformed[0..payload.len]));

    malformed = buffer;
    const length = std.mem.readInt(u32, malformed[metadata_length_offset..][0..4], .little);
    std.mem.writeInt(u32, malformed[metadata_length_offset..][0..4], length - 1, .little);
    try std.testing.expectError(error.Truncated, messages.decodeServer(malformed[0..payload.len]));

    malformed = buffer;
    std.mem.writeInt(u32, malformed[metadata_length_offset..][0..4], length + 1, .little);
    try std.testing.expectError(error.TrailingBytes, messages.decodeServer(malformed[0..payload.len]));

    const decoded = (try messages.decodeServer(payload)).pane_frame;
    const run_offset = @intFromPtr(decoded.text_metadata.?.run_bytes.ptr) - @intFromPtr(payload.ptr);
    malformed = buffer;
    std.mem.writeInt(u16, malformed[run_offset + 8 ..][0..2], 1, .little);
    try std.testing.expectError(error.InvalidTextMetadata, messages.decodeServer(malformed[0..payload.len]));
}

test "frame encoding validates provided metadata dimensions and run ranges" {
    var buffer: [1024]u8 = undefined;
    var scratch: [limits.capacity(2)]u8 = undefined;
    var builder = Builder.init(&scratch, 1);
    try std.testing.expectError(error.InvalidTextMetadata, snapshot(&buffer, builder.finish(.complete)));

    builder = Builder.init(&scratch, 2);
    const identity = try builder.addLink("https://example.test");
    try builder.addRun(.{ .start = 3, .len = 2, .link_index = identity });
    const invalid = builder.finish(.complete);
    try std.testing.expectError(error.InvalidTextMetadata, snapshot(&buffer, invalid));
    try std.testing.expectError(error.InvalidTextMetadata, patch(&buffer, invalid));
}
