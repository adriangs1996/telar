//! Protocol controller for agent session reports. Every request receives one
//! `request_completed` or `request_failed`.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const report_commands = @import("../../application/commands/report_agent_session.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Outcome = enum { recorded, unchanged, rejected };

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const ReportController = Controller(*report_commands.ReportAgentSessionHandler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueue,
        executor: Executor,

        pub fn init(responses: *ResponseQueue, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire report to its command and queues the reply.
        ///
        /// ```zig
        /// const outcome = try controller.reportAgentSession(request, now_ms);
        /// ```
        pub fn reportAgentSession(controller: *Self, request: schema.ReportAgentSession, now_ms: i64) !Outcome {
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

const StubExecutor = struct {
    result: report_commands.ReportAgentSessionResult = .recorded,
    command: ?report_commands.ReportAgentSession = null,

    fn execute(stub: *StubExecutor, command: report_commands.ReportAgentSession) report_commands.ReportAgentSessionResult {
        stub.command = command;
        return stub.result;
    }
};

test "Controller confirms recorded and unchanged reports and fails the rest" {
    var responses: ResponseQueue = .{};
    var stub: StubExecutor = .{};
    var controller = Controller(*StubExecutor).init(&responses, &stub);
    const request: schema.ReportAgentSession = .{
        .request_id = @enumFromInt(3),
        .pane_id = try schema.id.pane(7),
        .pane_generation = 2,
        .session = "0192abcd",
    };

    try std.testing.expectEqual(Outcome.recorded, try controller.reportAgentSession(request, 10));
    try std.testing.expectEqualStrings("0192abcd", stub.command.?.session);
    try std.testing.expect(responses.items[0] == .request_completed);

    stub.result = .pane_not_found;
    try std.testing.expectEqual(Outcome.rejected, try controller.reportAgentSession(request, 10));
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, responses.items[1].request_failed.code);

    stub.result = .invalid_session;
    try std.testing.expectEqual(Outcome.rejected, try controller.reportAgentSession(request, 10));
    try std.testing.expectEqual(schema.FailureCode.invalid_request, responses.items[2].request_failed.code);
}
