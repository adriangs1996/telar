//! Protocol controller for agent title reports. Every request receives one
//! `request_completed` or `request_failed`.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const report_commands = @import("../../application/commands/report_agent_title.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Outcome = enum { recorded, unchanged, rejected };

pub const Controller = @import("GenericReportAgentTitleController.zig").Type;

const StubExecutor = @import("ReportAgentTitleStubExecutor.zig");

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
