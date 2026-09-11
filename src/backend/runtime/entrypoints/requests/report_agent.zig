//! Protocol controller for agent lifecycle reports. Every request receives
//! one `request_completed` or `request_failed`; the audible transition and
//! checkpoint bookkeeping belong to the caller.

const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const ReportAgentStubExecutor = @import("ReportAgentStubExecutor.zig");
const GenericReportAgentController = @import("GenericReportAgentController.zig").Type;
const ReportAgentType = @import("telar-core").ReportAgent;
const pane_module = @import("telar-core").pane;
const std = @import("std");
const AgentReportStateType = @import("telar-core").AgentReportState;
const FailureCodeType = @import("telar-core").FailureCode;

test "Controller confirms applied reports and fails unknown panes" {
    var responses: ResponseQueue = .{};
    var stub: ReportAgentStubExecutor = .{};
    var controller = GenericReportAgentController(*ReportAgentStubExecutor).init(&responses, &stub);
    const request: ReportAgentType = .{
        .request_id = @enumFromInt(3),
        .pane_id = try pane_module(7),
        .pane_generation = 2,
        .state = .blocked,
    };

    _ = try controller.reportAgent(request, .{ .real_ms = 10, .awake_ns = 123 });
    try std.testing.expectEqual(@as(i64, 123), stub.command.?.now_ns.?);
    try std.testing.expectEqual(AgentReportStateType.blocked, stub.command.?.state);
    try std.testing.expect(responses.items[0] == .request_completed);

    stub.result = .{ .outcome = .pane_not_found };
    _ = try controller.reportAgent(request, .{ .real_ms = 10, .awake_ns = 124 });
    try std.testing.expectEqual(FailureCodeType.pane_not_found, responses.items[1].request_failed.code);
}
