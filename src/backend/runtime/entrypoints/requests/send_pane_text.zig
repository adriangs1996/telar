//! Protocol controller for text sent to a pane by a control client. Every
//! request receives exactly one `request_completed` or `request_failed`.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const send_pane_text_commands = @import("../../application/commands/send_pane_text.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("GenericSendPaneTextController.zig").Type;

const StubExecutor = @import("SendPaneTextStubExecutor.zig");

const TestController = Controller(*StubExecutor);

test "Controller confirms a handled send and maps every refusal to a failure code" {
    var responses: ResponseQueue = .{};
    var stub: StubExecutor = .{};
    var controller = TestController.init(&responses, &stub);
    const request: schema.SendPaneText = .{
        .request_id = @enumFromInt(4),
        .pane_id = try schema.id.pane(7),
        .pane_generation = 3,
        .mode = .prompt,
        .text = "ls",
    };

    try controller.sendPaneText(request);
    try std.testing.expectEqual(@as(u64, 3), stub.command.?.pane.generation);
    try std.testing.expectEqual(schema.PaneTextMode.prompt, stub.command.?.mode);
    try std.testing.expect(responses.items[0] == .request_completed);

    stub.result = .agent_blocked;
    try controller.sendPaneText(request);
    try std.testing.expectEqual(schema.FailureCode.agent_blocked, responses.items[1].request_failed.code);

    stub.result = .pane_exited;
    try controller.sendPaneText(request);
    try std.testing.expectEqual(schema.FailureCode.pane_exited, responses.items[2].request_failed.code);

    stub.result = .pane_not_found;
    try controller.sendPaneText(request);
    try std.testing.expectEqual(schema.FailureCode.pane_not_found, responses.items[3].request_failed.code);
}
