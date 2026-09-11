//! Vertical contract tests for the runtime create-pane flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const CreatePaneTestEffects = @import("CreatePaneTestEffects.zig");
const pane_module = @import("telar-core").pane;
const CreatePaneHandlerType = @import("../application/commands/CreatePaneHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const CreatePaneController = @import("../entrypoints/requests/CreatePaneController.zig");

test "a committed pane launch survives response queue backpressure" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var effects: CreatePaneTestEffects = .{ .launched = .{
        .key = .{ .id = try pane_module(17), .generation = 9 },
        .location = location,
    } };
    var handler: CreatePaneHandlerType = .{
        .workspaces = workspaces.reader(),
        .panes = effects.panes(),
        .authority = effects.authority(),
        .launcher = effects.launcher(),
        .attachment = effects.attachment(),
        .events = effects.publisher(),
    };
    var responses: ResponseQueueType = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    var controller = CreatePaneController.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.createPane(.{
        .request_id = @enumFromInt(31),
        .location = location,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = .{
            .cwd = "/requested",
            .argument_count = 1,
            .encoded_arguments = "\x07\x00/bin/sh",
            .environment_mode = .inherit_runtime,
            .environment_count = 0,
            .encoded_environment = "",
        },
    }));

    try std.testing.expectEqual(@as(usize, 1), effects.event_count);
    try std.testing.expectEqual(@as(usize, 1), effects.attachment_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
