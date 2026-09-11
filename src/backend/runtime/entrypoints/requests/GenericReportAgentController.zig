const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const ReportAgentType = @import("telar-core").ReportAgent;
const ClockType = @import("../../../history/Clock.zig");
const ReportAgentResultType = @import("../../application/commands/ReportAgentResult.zig");

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const ReportController = Controller(*report_commands.ReportAgentHandler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueueType,
        executor: Executor,

        pub fn init(responses: *ResponseQueueType, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire report to its command, queues the reply and returns
        /// the command result for transition effects.
        ///
        /// ```zig
        /// const result = try controller.reportAgent(request, clock);
        /// ```
        pub fn reportAgent(controller: *Self, request: ReportAgentType, clock: ClockType) !ReportAgentResultType {
            const result = controller.executor.execute(.{
                .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
                .state = request.state,
                .session = request.session,
                .session_file = .{ .kind = request.session_file_kind, .path = request.session_file },
                .now_ms = clock.real_ms,
                .now_ns = clock.awake_ns,
            });

            switch (result.outcome) {
                .applied, .unchanged => try controller.responses.push(.{ .request_completed = .{ .request_id = request.request_id } }),
                .pane_not_found => try controller.responses.push(.{ .request_failed = .{
                    .request_id = request.request_id,
                    .code = .pane_not_found,
                    .message = "pane not found",
                } }),
                .invalid_session => try controller.responses.push(.{ .request_failed = .{
                    .request_id = request.request_id,
                    .code = .invalid_request,
                    .message = "invalid session reference",
                } }),
            }

            return result;
        }
    };
}
