//! Protocol controller for agent lifecycle reports. Every request receives
//! one `request_completed` or `request_failed`; the audible transition and
//! checkpoint bookkeeping belong to the caller.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const report_commands = @import("../../application/commands/report_agent.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const ReportController = Controller(*report_commands.ReportAgentHandler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueue,
        executor: Executor,

        pub fn init(responses: *ResponseQueue, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire report to its command, queues the reply and returns
        /// the command result for transition effects.
        ///
        /// ```zig
        /// const result = try controller.reportAgent(request, now_ms);
        /// ```
        pub fn reportAgent(controller: *Self, request: schema.ReportAgent, now_ms: i64) !report_commands.ReportAgentResult {
            const result = controller.executor.execute(.{
                .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
                .state = request.state,
                .session = request.session,
                .session_file = .{ .kind = request.session_file_kind, .path = request.session_file },
                .now_ms = now_ms,
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

const StubExecutor = struct {
    result: report_commands.ReportAgentResult = .{ .outcome = .applied },
    command: ?report_commands.ReportAgent = null,

    fn execute(stub: *StubExecutor, command: report_commands.ReportAgent) report_commands.ReportAgentResult {
        stub.command = command;
        return stub.result;
    }
};

test "Controller confirms applied reports and fails unknown panes" {
    var responses: ResponseQueue = .{};
    var stub: StubExecutor = .{};
    var controller = Controller(*StubExecutor).init(&responses, &stub);
    const request: schema.ReportAgent = .{
        .request_id = @enumFromInt(3),
        .pane_id = try schema.id.pane(7),
        .pane_generation = 2,
        .state = .blocked,
    };

    _ = try controller.reportAgent(request, 10);
    try std.testing.expectEqual(schema.AgentReportState.blocked, stub.command.?.state);
    try std.testing.expect(responses.items[0] == .request_completed);

    stub.result = .{ .outcome = .pane_not_found };
    _ = try controller.reportAgent(request, 10);
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, responses.items[1].request_failed.code);
}
