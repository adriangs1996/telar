//! Protocol controller for text sent to a pane by a control client. Every
//! request receives exactly one `request_completed` or `request_failed`.

const GenericSendPaneTextController = @import("GenericSendPaneTextController.zig").Type;
const SendPaneTextStubExecutor = @import("SendPaneTextStubExecutor.zig");
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const SendPaneTextType = @import("telar-core").SendPaneText;
const pane_module = @import("telar-core").pane;
const std = @import("std");
const PaneTextModeType = @import("telar-core").PaneTextMode;
const FailureCodeType = @import("telar-core").FailureCode;

const TestController = GenericSendPaneTextController(*SendPaneTextStubExecutor);

test "Controller confirms a handled send and maps every refusal to a failure code" {
    var responses: ResponseQueue = .{};
    var stub: SendPaneTextStubExecutor = .{};
    var controller = TestController.init(&responses, &stub);
    const request: SendPaneTextType = .{
        .request_id = @enumFromInt(4),
        .pane_id = try pane_module(7),
        .pane_generation = 3,
        .mode = .prompt,
        .text = "ls",
    };

    try controller.sendPaneText(request);
    try std.testing.expectEqual(@as(u64, 3), stub.command.?.pane.generation);
    try std.testing.expectEqual(PaneTextModeType.prompt, stub.command.?.mode);
    try std.testing.expect(responses.items[0] == .request_completed);

    stub.result = .agent_blocked;
    try controller.sendPaneText(request);
    try std.testing.expectEqual(FailureCodeType.agent_blocked, responses.items[1].request_failed.code);

    stub.result = .pane_exited;
    try controller.sendPaneText(request);
    try std.testing.expectEqual(FailureCodeType.pane_exited, responses.items[2].request_failed.code);

    stub.result = .pane_not_found;
    try controller.sendPaneText(request);
    try std.testing.expectEqual(FailureCodeType.pane_not_found, responses.items[3].request_failed.code);
}
