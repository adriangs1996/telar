//! Protocol controller for agent lifecycle reports. Every request receives
//! one `request_completed` or `request_failed`; the audible transition and
//! checkpoint bookkeeping belong to the caller.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const report_commands = @import("../../application/commands/report_agent.zig");
const history = @import("../../../history/root.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("GenericReportAgentController.zig").Type;

const StubExecutor = @import("ReportAgentStubExecutor.zig");

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

    _ = try controller.reportAgent(request, .{ .real_ms = 10, .awake_ns = 123 });
    try std.testing.expectEqual(@as(i64, 123), stub.command.?.now_ns.?);
    try std.testing.expectEqual(schema.AgentReportState.blocked, stub.command.?.state);
    try std.testing.expect(responses.items[0] == .request_completed);

    stub.result = .{ .outcome = .pane_not_found };
    _ = try controller.reportAgent(request, .{ .real_ms = 10, .awake_ns = 124 });
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, responses.items[1].request_failed.code);
}
