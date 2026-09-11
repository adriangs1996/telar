//! Vertical tests for bounded pane text reads.

const PaneFixture = @import("PaneFixture.zig");
const std = @import("std");
const max_pane_text_bytes_module = @import("telar-core").max_pane_text_bytes;
const max_pane_text_rows_module = @import("telar-core").max_pane_text_rows;
const PaneStoreType = @import("../../pane/PaneStore.zig");
const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const ReadPaneController = @import("../entrypoints/requests/ReadPaneController.zig");
const max_frame_size_module = @import("telar-core").max_frame_size;
const QueryResultType = @import("../../history/QueryResult.zig");
const OutputResultType = @import("../../history/OutputResult.zig");
const StatsResultType = @import("../../history/StatsResult.zig");
const EncodeContextType = @import("../delivery/EncodeContext.zig");
const decodeServer_module = @import("telar-core").decodeServer;
const encoder = @import("../delivery/encoder.zig");
const FailureCodeType = @import("telar-core").FailureCode;

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

test "read crosses controller and encoder and degrades to a failure for a gone pane" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try ingestLines(&fixture);
    var panes: PaneStoreType = .{};
    try panes.insert(fixture.pane);
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var responses: ResponseQueueType = .{};
    var controller = ReadPaneController.init(&responses);
    const buffer = try std.testing.allocator.alloc(u8, max_frame_size_module);
    defer std.testing.allocator.free(buffer);
    var history_result: ?*QueryResultType = null;
    var history_output: ?*OutputResultType = null;
    var history_stats: ?*StatsResultType = null;
    const context: EncodeContextType = .{
        .buffer = buffer,
        .panes = &panes,
        .workspaces = workspaces.reader(),
        .history_result = &history_result,
        .history_output = &history_output,
        .history_stats = &history_stats,
    };

    try controller.readPane(.{
        .request_id = @enumFromInt(3),
        .pane_id = fixture.pane.id,
        .pane_generation = fixture.pane.generation,
        .rows = 3,
        .source = .recent,
    });
    const text = (try decodeServer_module(try encoder.encodeResponse(context, &responses.items[0]))).pane_text;

    try std.testing.expectEqual(@as(u64, 3), @intFromEnum(text.request_id));
    try std.testing.expectEqual(fixture.pane.id, text.pane_id);
    try std.testing.expect(!text.truncated);
    try std.testing.expectEqualStrings("six\nseven", text.text);

    try controller.readPane(.{
        .request_id = @enumFromInt(4),
        .pane_id = fixture.pane.id,
        .pane_generation = fixture.pane.generation + 1,
        .rows = 2,
        .source = .screen,
    });
    const failure = (try decodeServer_module(try encoder.encodeResponse(context, &responses.items[1]))).request_failed;

    try std.testing.expectEqual(@as(u64, 4), @intFromEnum(failure.request_id));
    try std.testing.expectEqual(FailureCodeType.pane_not_found, failure.code);
}
