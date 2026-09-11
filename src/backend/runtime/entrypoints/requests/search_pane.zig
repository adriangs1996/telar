//! Protocol controller for copy-mode search. Every request receives one
//! `pane_matches` or `request_failed`.

const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const SearchPaneStubExecutor = @import("SearchPaneStubExecutor.zig");
const GenericSearchPaneController = @import("GenericSearchPaneController.zig").Type;
const SearchPaneType = @import("telar-core").SearchPane;
const pane_module = @import("telar-core").pane;
const std = @import("std");
const FailureCodeType = @import("telar-core").FailureCode;
const MatchesType = @import("../../application/commands/Matches.zig");

test "Controller queues matches or a failure" {
    var responses: ResponseQueue = .{};
    var stub: SearchPaneStubExecutor = .{};
    var controller = GenericSearchPaneController(*SearchPaneStubExecutor).init(&responses, &stub);
    const request: SearchPaneType = .{ .request_id = @enumFromInt(2), .pane_id = try pane_module(7), .needle = "x" };

    try controller.searchPane(request);
    try std.testing.expectEqual(FailureCodeType.pane_not_found, responses.items[0].request_failed.code);

    var matches: MatchesType = .{};
    matches.items[0] = .{ .x = 1, .y = 2, .len = 1 };
    matches.count = 1;
    stub.result = .{ .found = matches };
    try controller.searchPane(request);
    try std.testing.expectEqual(@as(u8, 1), responses.items[1].pane_matches.matches.count);
}
