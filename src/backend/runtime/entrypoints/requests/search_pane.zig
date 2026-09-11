//! Protocol controller for copy-mode search. Every request receives one
//! `pane_matches` or `request_failed`.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const search_commands = @import("../../application/commands/search_pane.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("GenericSearchPaneController.zig").Type;

const StubExecutor = @import("SearchPaneStubExecutor.zig");

test "Controller queues matches or a failure" {
    var responses: ResponseQueue = .{};
    var stub: StubExecutor = .{};
    var controller = Controller(*StubExecutor).init(&responses, &stub);
    const request: schema.SearchPane = .{ .request_id = @enumFromInt(2), .pane_id = try schema.id.pane(7), .needle = "x" };

    try controller.searchPane(request);
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, responses.items[0].request_failed.code);

    var matches: search_commands.Matches = .{};
    matches.items[0] = .{ .x = 1, .y = 2, .len = 1 };
    matches.count = 1;
    stub.result = .{ .found = matches };
    try controller.searchPane(request);
    try std.testing.expectEqual(@as(u8, 1), responses.items[1].pane_matches.matches.count);
}
