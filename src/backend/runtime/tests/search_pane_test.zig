//! Vertical tests for copy-mode search over pane history.

const PaneFixture = @import("PaneFixture.zig");
const std = @import("std");
const CursorType = @import("../../pane/Cursor.zig");
const SearchPaneHandlerType = @import("../application/commands/SearchPaneHandler.zig");
const SearchMatchType = @import("telar-core").SearchMatch;
const pane_module = @import("telar-core").pane;

test "search turns are bounded, wait for VT ownership and reject changed history" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    for (0..100) |_| {
        _ = try fixture.pane.ingest(std.testing.io, "aaaaab\r\n");
    }
    const Cursor = CursorType;
    var cursor = Cursor.init("missing");
    fixture.pane.ingest_pending = true;
    try std.testing.expect(!try cursor.advance(fixture.pane));
    try std.testing.expect(cursor.revision == null);
    fixture.pane.ingest_pending = false;
    try std.testing.expect(!try cursor.advance(fixture.pane));
    try std.testing.expectEqual(@as(usize, Cursor.rows_per_turn), cursor.next_row);
    _ = try fixture.pane.ingest(std.testing.io, "changed");
    try std.testing.expectError(error.SearchInvalidated, cursor.advance(fixture.pane));
}

test "linear search preserves non-overlap and wide-cell coordinates" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.pane.ingest(std.testing.io, "aaaaa\r\n界x界x");
    var handler: SearchPaneHandlerType = .{ .attachments = &fixture.attachments };
    const ascii = handler.execute(.{ .pane_id = fixture.pane.id, .needle = "aa" }).found;
    try std.testing.expectEqual(@as(u8, 2), ascii.count);
    try std.testing.expectEqual(@as(u16, 0), ascii.items[0].x);
    try std.testing.expectEqual(@as(u16, 2), ascii.items[1].x);
    const wide = handler.execute(.{ .pane_id = fixture.pane.id, .needle = "x界" }).found;
    try std.testing.expectEqual(@as(u8, 1), wide.count);
    try std.testing.expectEqual(@as(u16, 2), wide.items[0].x);
    try std.testing.expectEqual(@as(u16, 2), wide.items[0].len);
}

test "search finds matches in document order with absolute rows and folds ASCII case" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.pane.ingest(std.testing.io, "zero\r\nError one\r\ntwo\r\nthree error four\r\nfive\r\nsix\r\nseven\r\n");
    try fixture.pane.render(false);
    var handler: SearchPaneHandlerType = .{ .attachments = &fixture.attachments };

    const found = handler.execute(.{ .pane_id = fixture.pane.id, .needle = "error" }).found;

    try std.testing.expectEqual(@as(u8, 2), found.count);
    try std.testing.expect(!found.truncated);
    try std.testing.expectEqualDeep(SearchMatchType{ .x = 0, .y = 1, .len = 5 }, found.items[0]);
    try std.testing.expectEqualDeep(SearchMatchType{ .x = 6, .y = 3, .len = 5 }, found.items[1]);

    const sensitive = handler.execute(.{ .pane_id = fixture.pane.id, .needle = "Error" }).found;
    try std.testing.expectEqual(@as(u8, 1), sensitive.count);
    try std.testing.expectEqual(@as(u32, 1), sensitive.items[0].y);

    try std.testing.expect(handler.execute(.{ .pane_id = try pane_module(99), .needle = "x" }) == .pane_not_attached);
}
