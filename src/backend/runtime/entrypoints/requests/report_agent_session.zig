//! Protocol controller for agent session reports. Every request receives one
//! `request_completed` or `request_failed`.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const report_commands = @import("../../application/commands/report_agent_session.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Outcome = enum { recorded, unchanged, rejected };

pub const Controller = @import("GenericReportAgentSessionController.zig").Type;

const StubExecutor = @import("ReportAgentSessionStubExecutor.zig");

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
