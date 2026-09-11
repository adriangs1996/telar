const source_namespace = @import("report_agent_title.zig");
/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const ReportController = Controller(*report_commands.ReportAgentTitleHandler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *source_namespace.ResponseQueue,
        executor: Executor,

        pub fn init(responses: *source_namespace.ResponseQueue, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire report to its command and queues the reply.
        ///
        /// ```zig
        /// const outcome = try controller.reportAgentTitle(request);
        /// ```
        pub fn reportAgentTitle(controller: *Self, request: source_namespace.schema.ReportAgentTitle) !source_namespace.Outcome {
            const result = controller.executor.execute(.{
                .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
                .title = request.title,
            });

            switch (result) {
                .recorded, .unchanged => {
                    try controller.responses.push(.{ .request_completed = .{ .request_id = request.request_id } });
                    return if (result == .recorded) .recorded else .unchanged;
                },
                .pane_not_found => {
                    try controller.responses.push(.{ .request_failed = .{
                        .request_id = request.request_id,
                        .code = .pane_not_found,
                        .message = "pane not found",
                    } });
                    return .rejected;
                },
                .invalid_title => {
                    try controller.responses.push(.{ .request_failed = .{
                        .request_id = request.request_id,
                        .code = .invalid_request,
                        .message = "invalid session title",
                    } });
                    return .rejected;
                },
            }
        }
    };
}
