//! Vertical tests for bounded pane text reads.

const PaneFixture = @import("PaneFixture.zig");
const std = @import("std");
const max_pane_text_bytes_module = @import("telar-core").max_pane_text_bytes;
const max_pane_text_rows_module = @import("telar-core").max_pane_text_rows;

fn ingestLines(fixture: *PaneFixture) !void {
    _ = try fixture.pane.ingest(
        std.testing.io,
        "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n",
    );
    try fixture.pane.render(false);
}

test "recent rows dump scrollback and screen as plain text, newest last" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try ingestLines(&fixture);
    var storage: [max_pane_text_bytes_module]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = 3, .source = .recent }, &storage);

    try std.testing.expect(!dump.truncated);
    try std.testing.expectEqualStrings("six\nseven", storage[0..dump.len]);
}

test "screen rows never reach into scrollback" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try ingestLines(&fixture);
    var storage: [max_pane_text_bytes_module]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = max_pane_text_rows_module, .source = .screen }, &storage);

    try std.testing.expect(!dump.truncated);
    try std.testing.expectEqualStrings("four\nfive\nsix\nseven", storage[0..dump.len]);
}

test "a dump that does not fit keeps a prefix and reports truncation" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try ingestLines(&fixture);
    var storage: [4]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = 3, .source = .recent }, &storage);

    try std.testing.expect(dump.truncated);
    try std.testing.expectEqual(@as(usize, 4), dump.len);
}
