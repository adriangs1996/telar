const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const ReportAgentSessionType = @import("telar-core").ReportAgentSession;
const report_agent_session = @import("report_agent_session.zig");

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const ReportController = Controller(*report_commands.ReportAgentSessionHandler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueueType,
        executor: Executor,

        pub fn init(responses: *ResponseQueueType, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire report to its command and queues the reply.
        ///
        /// ```zig
        /// const outcome = try controller.reportAgentSession(request, now_ms);
        /// ```
        pub fn reportAgentSession(controller: *Self, request: ReportAgentSessionType, now_ms: i64) !report_agent_session.Outcome {
            const result = controller.executor.execute(.{
                .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
                .session = request.session,
                .now_ms = now_ms,
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
                .invalid_session => {
                    try controller.responses.push(.{ .request_failed = .{
                        .request_id = request.request_id,
                        .code = .invalid_request,
                        .message = "invalid session reference",
                    } });
                    return .rejected;
                },
            }
        }
    };
}
