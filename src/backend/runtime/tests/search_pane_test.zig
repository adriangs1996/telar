//! Vertical tests for copy-mode search over pane history.

const std = @import("std");
const core = @import("telar-core");
const search_commands = @import("../application/commands/search_pane.zig");
const test_support = @import("support.zig");

const schema = core.schema;
const PaneFixture = test_support.PaneFixture;

test "search finds matches in document order with absolute rows and folds ASCII case" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.pane.ingest(std.testing.io, "zero\r\nError one\r\ntwo\r\nthree error four\r\nfive\r\nsix\r\nseven\r\n");
    try fixture.pane.render(false);
    var handler: search_commands.SearchPaneHandler = .{ .attachments = &fixture.attachments };

    const found = handler.execute(.{ .pane_id = fixture.pane.id, .needle = "error" }).found;

    try std.testing.expectEqual(@as(u8, 2), found.count);
    try std.testing.expect(!found.truncated);
    try std.testing.expectEqualDeep(schema.SearchMatch{ .x = 0, .y = 1, .len = 5 }, found.items[0]);
    try std.testing.expectEqualDeep(schema.SearchMatch{ .x = 6, .y = 3, .len = 5 }, found.items[1]);

    const sensitive = handler.execute(.{ .pane_id = fixture.pane.id, .needle = "Error" }).found;
    try std.testing.expectEqual(@as(u8, 1), sensitive.count);
    try std.testing.expectEqual(@as(u32, 1), sensitive.items[0].y);

    try std.testing.expect(handler.execute(.{ .pane_id = try schema.id.pane(99), .needle = "x" }) == .pane_not_attached);
}
