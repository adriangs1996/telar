const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const ReportAgentCommandType = @import("telar-core").ReportAgentCommand;

pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueueType,
        executor: Executor,

        pub fn init(responses: *ResponseQueueType, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps one wire report to history persistence and acknowledges it.
        ///
        /// ```zig
        /// try controller.reportAgentCommand(request, now_ms);
        /// ```
        pub fn reportAgentCommand(controller: *Self, request: ReportAgentCommandType, now_ms: i64) !void {
            const outcome = controller.executor.execute(.{
                .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
                .phase = request.phase,
                .provider = request.provider,
                .tool_call_id = request.tool_call_id,
                .command = request.command,
                .cwd = request.cwd,
                .exit_code = request.exit_code,
                .now_ms = now_ms,
            });

            switch (outcome) {
                .applied => try controller.responses.push(.{ .request_completed = .{ .request_id = request.request_id } }),
                .pane_not_found => try controller.responses.push(.{ .request_failed = .{
                    .request_id = request.request_id,
                    .code = .pane_not_found,
                    .message = "pane not found",
                } }),
                .queue_full => try controller.responses.push(.{ .request_failed = .{
                    .request_id = request.request_id,
                    .code = .resource_limit,
                    .message = "history queue full",
                } }),
            }
        }
    };
}
