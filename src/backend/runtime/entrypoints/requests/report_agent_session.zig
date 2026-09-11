//! Protocol controller for agent session reports. Every request receives one
//! `request_completed` or `request_failed`.

const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const ReportAgentSessionStubExecutor = @import("ReportAgentSessionStubExecutor.zig");
const GenericReportAgentSessionController = @import("GenericReportAgentSessionController.zig").Type;
const ReportAgentSessionType = @import("telar-core").ReportAgentSession;
const pane_module = @import("telar-core").pane;
const std = @import("std");
const FailureCodeType = @import("telar-core").FailureCode;

pub const Outcome = enum { recorded, unchanged, rejected };

test "Controller confirms recorded and unchanged reports and fails the rest" {
    var responses: ResponseQueue = .{};
    var stub: ReportAgentSessionStubExecutor = .{};
    var controller = GenericReportAgentSessionController(*ReportAgentSessionStubExecutor).init(&responses, &stub);
    const request: ReportAgentSessionType = .{
        .request_id = @enumFromInt(3),
        .pane_id = try pane_module(7),
        .pane_generation = 2,
        .session = "0192abcd",
    };

    try std.testing.expectEqual(Outcome.recorded, try controller.reportAgentSession(request, 10));
    try std.testing.expectEqualStrings("0192abcd", stub.command.?.session);
    try std.testing.expect(responses.items[0] == .request_completed);

    stub.result = .pane_not_found;
    try std.testing.expectEqual(Outcome.rejected, try controller.reportAgentSession(request, 10));
    try std.testing.expectEqual(FailureCodeType.pane_not_found, responses.items[1].request_failed.code);

    stub.result = .invalid_session;
    try std.testing.expectEqual(Outcome.rejected, try controller.reportAgentSession(request, 10));
    try std.testing.expectEqual(FailureCodeType.invalid_request, responses.items[2].request_failed.code);
}
