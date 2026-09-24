//! Vertical tests for copy-mode search over pane history.

const PaneFixture = @import("PaneFixture.zig");
const std = @import("std");
const CursorType = @import("../../pane/text_search.zig").Search;

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
