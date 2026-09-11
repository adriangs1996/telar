//! Protocol controller for agent title reports. Every request receives one
//! `request_completed` or `request_failed`.

const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const ReportAgentTitleStubExecutor = @import("ReportAgentTitleStubExecutor.zig");
const GenericReportAgentTitleController = @import("GenericReportAgentTitleController.zig").Type;
const ReportAgentTitleType = @import("telar-core").ReportAgentTitle;
const pane_module = @import("telar-core").pane;
const std = @import("std");
const FailureCodeType = @import("telar-core").FailureCode;

pub const Outcome = enum { recorded, unchanged, rejected };

test "Controller confirms recorded and unchanged titles and fails the rest" {
    var responses: ResponseQueue = .{};
    var stub: ReportAgentTitleStubExecutor = .{};
    var controller = GenericReportAgentTitleController(*ReportAgentTitleStubExecutor).init(&responses, &stub);
    const request: ReportAgentTitleType = .{
        .request_id = @enumFromInt(3),
        .pane_id = try pane_module(7),
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
    try std.testing.expectEqual(FailureCodeType.pane_not_found, responses.items[2].request_failed.code);

    stub.result = .invalid_title;
    try std.testing.expectEqual(Outcome.rejected, try controller.reportAgentTitle(request));
    try std.testing.expectEqual(FailureCodeType.invalid_request, responses.items[3].request_failed.code);
}
