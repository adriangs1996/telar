//! Protocol controller for text sent to a pane by a control client. Every
//! request receives exactly one `request_completed` or `request_failed`.

const std = @import("std");
const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const send_pane_text_commands = @import("../../application/commands/send_pane_text.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

/// Builds a statically dispatched controller around one executor.
///
/// ```zig
/// const SendPaneTextController = Controller(*send_pane_text_commands.SendPaneTextHandler);
/// var controller = SendPaneTextController.init(&responses, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        responses: *ResponseQueue,
        executor: Executor,

        /// Creates one controller bound to the requesting client's responses.
        ///
        /// ```zig
        /// var controller = SendPaneTextController.init(&responses, &handler);
        /// ```
        pub fn init(responses: *ResponseQueue, executor: Executor) Self {
            return .{ .responses = responses, .executor = executor };
        }

        /// Maps the wire request to its command and queues the terminal reply.
        ///
        /// ```zig
        /// try controller.sendPaneText(request);
        /// ```
        pub fn sendPaneText(controller: *Self, request: schema.SendPaneText) !void {
            const result = try controller.executor.execute(.{
                .pane = .{ .id = request.pane_id, .generation = request.pane_generation },
                .mode = request.mode,
                .text = request.text,
            });

            switch (result) {
                .handled => try controller.responses.push(.{ .request_completed = .{
                    .request_id = request.request_id,
                } }),
                .pane_not_found => try controller.fail(.{
                    .request_id = request.request_id,
                    .code = .pane_not_found,
                    .message = "pane not found",
                }),
                .pane_exited => try controller.fail(.{
                    .request_id = request.request_id,
                    .code = .pane_exited,
                    .message = "pane already exited",
                }),
                .agent_blocked => try controller.fail(.{
                    .request_id = request.request_id,
                    .code = .agent_blocked,
                    .message = "agent is waiting for a decision",
                }),
            }
        }

        fn fail(controller: *Self, failure: delivery_mod.PendingFailure) !void {
            try controller.responses.push(.{ .request_failed = failure });
        }
    };
}

const StubExecutor = struct {
    result: send_pane_text_commands.SendPaneTextResult = .handled,
    command: ?send_pane_text_commands.SendPaneText = null,

    fn execute(stub: *StubExecutor, command: send_pane_text_commands.SendPaneText) !send_pane_text_commands.SendPaneTextResult {
        stub.command = command;
        return stub.result;
    }
};

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
