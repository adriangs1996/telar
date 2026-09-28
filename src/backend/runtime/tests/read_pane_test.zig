//! Vertical tests for bounded pane text reads.

const core = @import("telar-core");
const PaneFixture = @import("PaneFixture.zig");
const std = @import("std");
const PaneKey = @import("../../pane/PaneKey.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const encoder = @import("../delivery/encoder.zig");
const response_queue = @import("../delivery/response_queue.zig");

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
    var storage: [core.max_pane_text_bytes]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = 3, .source = .recent }, &storage);

    try std.testing.expect(!dump.truncated);
    try std.testing.expectEqualStrings("six\nseven", storage[0..dump.len]);
}

test "screen rows never reach into scrollback" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try ingestLines(&fixture);
    var storage: [core.max_pane_text_bytes]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = core.max_pane_text_rows, .source = .screen }, &storage);

    try std.testing.expect(!dump.truncated);
    try std.testing.expectEqualStrings("four\nfive\nsix\nseven", storage[0..dump.len]);
}

test "a dump that does not fit keeps the newest whole lines and reports truncation" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try ingestLines(&fixture);
    var storage: [8]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = 3, .source = .recent }, &storage);

    try std.testing.expect(dump.truncated);
    try std.testing.expectEqualStrings("seven", storage[0..dump.len]);
}

test "a verbose command keeps its last line when its rows overflow the buffer" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var line_buffer: [32]u8 = undefined;
    for (1..2001) |number| {
        _ = try fixture.pane.ingest(std.testing.io, try std.fmt.bufPrint(&line_buffer, "line {d:0>4} ........\r\n", .{number}));
    }
    _ = try fixture.pane.ingest(std.testing.io, "3 passed, 1 failed");
    var storage: [1024]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = core.max_pane_text_rows, .source = .recent }, &storage);
    const text = storage[0..dump.len];

    try std.testing.expect(dump.truncated);
    try std.testing.expect(std.mem.endsWith(u8, text, "3 passed, 1 failed"));
    try std.testing.expect(std.mem.startsWith(u8, text, "line "));
    try std.testing.expect(std.mem.indexOf(u8, text, "line 2000 ........\n") != null);
}

test "a read of an exited pane serves its kept tail and says when older rows were dropped" {
    var panes: PaneStore = .{};
    const key: PaneKey = .{ .id = try core.pane(7), .generation = 3 };
    panes.exited.record(key, 1, .{
        .text = "line 1999\nline 2000\nFAILED: 1 test\n",
        .truncated = true,
    });

    const buffer = try std.testing.allocator.create([core.max_pane_text_bytes + 256]u8);
    defer std.testing.allocator.destroy(buffer);

    const last = try readExited(&panes, .{ .key = key, .rows = 1 }, buffer);
    try std.testing.expectEqualStrings("FAILED: 1 test", last.text);
    try std.testing.expect(!last.truncated);
    try std.testing.expectEqual(@as(?i32, 1), last.exit_code);

    const all = try readExited(&panes, .{ .key = key, .rows = core.max_pane_text_rows }, buffer);
    try std.testing.expectEqualStrings("line 1999\nline 2000\nFAILED: 1 test", all.text);
    try std.testing.expect(all.truncated);
}

const ExitedRead = struct {
    key: PaneKey,
    rows: u16,
};

/// Encodes a queued read of an exited pane into `buffer` and decodes it;
/// the text borrows `buffer`.
fn readExited(panes: *const PaneStore, read: ExitedRead, buffer: []u8) !core.PaneText {
    const key = read.key;
    const rows = read.rows;
    var workspaces: Workspaces = .{};
    var history_result: ?*QueryResult = null;
    var history_output: ?*OutputResult = null;
    var history_stats: ?*StatsResult = null;
    var response: response_queue.PendingResponse = .{ .pane_text = .{
        .request_id = @enumFromInt(9),
        .pane = key,
        .rows = rows,
        .source = .recent,
    } };

    const payload = try encoder.encodeResponse(.{
        .buffer = buffer,
        .panes = panes,
        .workspaces = &workspaces,
        .history_result = &history_result,
        .history_output = &history_output,
        .history_stats = &history_stats,
    }, &response);
    const decoded = try core.decodeServer(payload);
    try std.testing.expect(decoded == .pane_text);
    return decoded.pane_text;
}
