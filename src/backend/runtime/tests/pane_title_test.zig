//! Vertical tests for pane window titles: capture, sanitizing and delivery.

const std = @import("std");
const core = @import("telar-core");
const test_support = @import("support.zig");

const schema = core.schema;
const PaneFixture = test_support.PaneFixture;

test "an OSC 0 title is captured once and delivered to the attachment" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [512]u8 = undefined;

    _ = try fixture.pane.ingest(std.testing.io, "\x1b]0;vim README.md\x07");

    try std.testing.expectEqualStrings("vim README.md", fixture.pane.title.slice());
    const prepared = (try attachment.prepareTitle(&buffer)).?;
    const message = (try schema.decodeServer(prepared.bytes)).pane_title;
    try std.testing.expectEqual(fixture.pane.id, message.pane_id);
    try std.testing.expectEqualStrings("vim README.md", message.title);

    _ = attachment.commitPrepared(prepared);
    try std.testing.expect(try attachment.prepareTitle(&buffer) == null);

    _ = try fixture.pane.ingest(std.testing.io, "\x1b]0;vim README.md\x07");
    try std.testing.expect(try attachment.prepareTitle(&buffer) == null);
}

test "control bytes are dropped and a cleared title is delivered as empty" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const attachment = fixture.attachments.find(fixture.pane.id).?;
    var buffer: [512]u8 = undefined;

    _ = try fixture.pane.ingest(std.testing.io, "\x1b]2;a\x01b\x7fc\x07");
    try std.testing.expectEqualStrings("abc", fixture.pane.title.slice());
    _ = attachment.commitPrepared((try attachment.prepareTitle(&buffer)).?);

    _ = try fixture.pane.ingest(std.testing.io, "\x1b]0;\x07");
    try std.testing.expectEqualStrings("", fixture.pane.title.slice());
    const cleared = (try schema.decodeServer((try attachment.prepareTitle(&buffer)).?.bytes)).pane_title;
    try std.testing.expectEqualStrings("", cleared.title);
}

test "a long title is cut on a UTF-8 boundary" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var sequence: [8 + schema.max_pane_title_bytes + 8]u8 = undefined;
    var len: usize = 0;
    @memcpy(sequence[len .. len + 4], "\x1b]0;");
    len += 4;
    while (len + 3 <= 4 + schema.max_pane_title_bytes + 2) : (len += 3) {
        @memcpy(sequence[len .. len + 3], "é!"); // 2 + 1 bytes
    }
    sequence[len] = 0x07;
    len += 1;

    _ = try fixture.pane.ingest(std.testing.io, sequence[0..len]);

    const title = fixture.pane.title.slice();
    try std.testing.expect(title.len <= schema.max_pane_title_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(title));
}
