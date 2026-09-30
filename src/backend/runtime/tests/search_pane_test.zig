//! Vertical tests for copy-mode search over pane history.

const PaneFixture = @import("PaneFixture.zig");
const RequestFixture = @import("RequestFixture.zig");
const core = @import("telar-core");
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
    const total_rows = fixture.pane.terminal.screens.active.pages.total_rows;
    try std.testing.expect(!try cursor.advance(fixture.pane));
    try std.testing.expectEqual(total_rows - Cursor.rows_per_turn, cursor.next_row);
    _ = try fixture.pane.ingest(std.testing.io, "changed");
    try std.testing.expectError(error.SearchInvalidated, cursor.advance(fixture.pane));
}

test "a search with more matches than it keeps returns the newest ones in document order" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const lines = core.max_search_matches + 10;
    for (0..lines) |_| {
        _ = try fixture.pane.ingest(std.testing.io, "hit\r\n");
    }

    var matches: [core.max_search_matches]core.SearchMatch = undefined;
    const found = fixture.pane.searchText("hit", &matches);
    try std.testing.expectEqual(@as(u16, core.max_search_matches), found.count);
    try std.testing.expect(found.truncated);
    for (matches[1..], matches[0 .. matches.len - 1]) |current, previous| {
        try std.testing.expectEqual(previous.y + 1, current.y);
    }

    try std.testing.expectEqual(@as(u32, lines - 1), matches[matches.len - 1].y);
    try std.testing.expectEqual(@as(u32, lines - core.max_search_matches), matches[0].y);
}

test "a search out of time answers with what it found and reports its deadline" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const pane = try fixture.openPane();
    try fixture.send(.{ .search_pane = .{ .request_id = @enumFromInt(41), .pane_id = pane.id, .needle = "search" } });
    fixture.session.pending_search.?.deadline_ns = 0;

    while (true) {
        const completed = try fixture.runtime.loop.next();
        _ = try fixture.runtime.update(completed);
        if (completed == .pane_search) {
            break;
        }
    }

    const responses = &fixture.session.delivery.responses;
    while (responses.peek()) |response| {
        if (response.* == .pane_matches) {
            break;
        }

        responses.pop();
    }

    try std.testing.expect(responses.peek().?.pane_matches.matches.truncated);
    try std.testing.expect(fixture.session.pending_search == null);
    try std.testing.expect(fixture.runtime.model.limit_reaches.find("pane_search.deadline_ms") != null);
}
