const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const SendPaneTextType = @import("telar-core").SendPaneText;
const PendingFailureType = @import("../../delivery/PendingFailure.zig");

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const SendPaneTextController = Controller(*send_pane_text_commands.SendPaneTextHandler);
/// var controller = SendPaneTextController.init(&responses, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueueType,
        executor: Executor,

        /// Creates one controller bound to the requesting client's responses.
        ///
        /// ```zig
        /// var controller = SendPaneTextController.init(&responses, &handler);
        /// ```
        pub fn init(responses: *ResponseQueueType, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire request to its command and queues the terminal reply.
        ///
        /// ```zig
        /// try controller.sendPaneText(request);
        /// ```
        pub fn sendPaneText(controller: *Self, request: SendPaneTextType) !void {
            const result = try controller.executor.execute(.{
                .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
                .mode = request.mode,
                .text = request.text,
            });

            switch (result) {
                .handled => try controller.responses.push(.{ .request_completed = .{
                    .request_id = request.request_id,
                } }),
                .pane_not_found => try controller.fail(.{
                    .request_id = request.request_id,
                    .code = .pane_not_found,
                    .message = "pane not found",
                }),
                .pane_exited => try controller.fail(.{
                    .request_id = request.request_id,
                    .code = .pane_exited,
                    .message = "pane already exited",
                }),
                .agent_blocked => try controller.fail(.{
                    .request_id = request.request_id,
                    .code = .agent_blocked,
                    .message = "agent is waiting for a decision",
                }),
            }
        }

        fn fail(controller: *Self, failure: PendingFailureType) !void {
            try controller.responses.push(.{ .request_failed = failure });
        }
    };
}
