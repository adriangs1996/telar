//! Vertical tests for bounded pane text reads.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const delivery_mod = @import("../delivery/root.zig");
const encoder = @import("../delivery/encoder.zig");
const read_pane_controller = @import("../entrypoints/requests/read_pane.zig");
const history = @import("../../history/root.zig");
const test_support = @import("support.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const PaneFixture = test_support.PaneFixture;

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
    var storage: [schema.max_pane_text_bytes]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = 3, .source = .recent }, &storage);

    try std.testing.expect(!dump.truncated);
    try std.testing.expectEqualStrings("six\nseven", storage[0..dump.len]);
}

test "screen rows never reach into scrollback" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try ingestLines(&fixture);
    var storage: [schema.max_pane_text_bytes]u8 = undefined;

    const dump = fixture.pane.dumpText(.{ .rows = schema.max_pane_text_rows, .source = .screen }, &storage);

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
    var panes: pane_mod.PaneStore = .{};
    try panes.insert(fixture.pane);
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var responses: delivery_mod.ResponseQueue = .{};
    var controller = read_pane_controller.Controller.init(&responses);
    const buffer = try std.testing.allocator.alloc(u8, core.transport.max_frame_size);
    defer std.testing.allocator.free(buffer);
    var history_result: ?*history.model.QueryResult = null;
    var history_output: ?*history.model.OutputResult = null;
    var history_stats: ?*history.model.StatsResult = null;
    const context: encoder.EncodeContext = .{
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
    const text = (try schema.decodeServer(try encoder.encodeResponse(context, &responses.items[0]))).pane_text;

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
    const failure = (try schema.decodeServer(try encoder.encodeResponse(context, &responses.items[1]))).request_failed;

    try std.testing.expectEqual(@as(u64, 4), @intFromEnum(failure.request_id));
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, failure.code);
}
