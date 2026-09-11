const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const SearchPaneType = @import("telar-core").SearchPane;

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const SearchController = Controller(*search_commands.SearchPaneHandler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueueType,
        executor: Executor,

        pub fn init(responses: *ResponseQueueType, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire search to its command and queues the reply.
        ///
        /// ```zig
        /// try controller.searchPane(request);
        /// ```
        pub fn searchPane(controller: *Self, request: SearchPaneType) !void {
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
