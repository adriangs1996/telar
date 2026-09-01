//! Protocol controller for copy-mode search. Every request receives one
//! `pane_matches` or `request_failed`.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const search_commands = @import("../../application/commands/search_pane.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const SearchController = Controller(*search_commands.SearchPaneHandler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueue,
        executor: Executor,

        pub fn init(responses: *ResponseQueue, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire search to its command and queues the reply.
        ///
        /// ```zig
        /// try controller.searchPane(request);
        /// ```
        pub fn searchPane(controller: *Self, request: schema.SearchPane) !void {
            switch (controller.executor.execute(.{ .pane_id = request.pane_id, .needle = request.needle })) {
                .found => |matches| try controller.responses.push(.{ .pane_matches = .{
                    .request_id = request.request_id,
                    .pane_id = request.pane_id,
                    .matches = matches,
                } }),
                .pane_not_attached => try controller.responses.push(.{ .request_failed = .{
                    .request_id = request.request_id,
                    .code = .pane_not_found,
                    .message = "pane is not attached",
                } }),
            }
        }
    };
}

const StubExecutor = struct {
    result: search_commands.SearchPaneResult = .pane_not_attached,

    fn execute(stub: *StubExecutor, _: search_commands.SearchPane) search_commands.SearchPaneResult {
        return stub.result;
    }
};

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
