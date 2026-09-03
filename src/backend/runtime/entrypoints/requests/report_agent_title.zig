//! Protocol controller for agent title reports. Every request receives one
//! `request_completed` or `request_failed`.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const report_commands = @import("../../application/commands/report_agent_title.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Outcome = enum { recorded, unchanged, rejected };

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const ReportController = Controller(*report_commands.ReportAgentTitleHandler);
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
        /// const outcome = try controller.reportAgentTitle(request);
        /// ```
        pub fn reportAgentTitle(controller: *Self, request: schema.ReportAgentTitle) !Outcome {
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

const StubExecutor = struct {
    result: report_commands.ReportAgentTitleResult = .recorded,
    command: ?report_commands.ReportAgentTitle = null,

    fn execute(stub: *StubExecutor, command: report_commands.ReportAgentTitle) report_commands.ReportAgentTitleResult {
        stub.command = command;
        return stub.result;
    }
};

test "Controller confirms recorded and unchanged titles and fails the rest" {
    var responses: ResponseQueue = .{};
    var stub: StubExecutor = .{};
    var controller = Controller(*StubExecutor).init(&responses, &stub);
    const request: schema.ReportAgentTitle = .{
        .request_id = @enumFromInt(3),
        .pane_id = try schema.id.pane(7),
        .pane_generation = 2,
        .title = "Fix proxy",
    };

    try std.testing.expectEqual(Outcome.recorded, try controller.reportAgentTitle(request));
    try std.testing.expectEqualStrings("Fix proxy", stub.command.?.title);
    try std.testing.expect(responses.items[0] == .request_completed);

    stub.result = .unchanged;
    try std.testing.expectEqual(Outcome.unchanged, try controller.reportAgentTitle(request));
    try std.testing.expect(responses.items[1] == .request_completed);

    stub.result = .pane_not_found;
    try std.testing.expectEqual(Outcome.rejected, try controller.reportAgentTitle(request));
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, responses.items[2].request_failed.code);

    stub.result = .invalid_title;
    try std.testing.expectEqual(Outcome.rejected, try controller.reportAgentTitle(request));
    try std.testing.expectEqual(schema.FailureCode.invalid_request, responses.items[3].request_failed.code);
}
