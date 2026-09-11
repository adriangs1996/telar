//! Vertical contract tests for the runtime create-workspace flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const CreateWorkspaceTestEffects = @import("CreateWorkspaceTestEffects.zig");
const pane_module = @import("telar-core").pane;
const CreateWorkspaceHandlerType = @import("../application/commands/CreateWorkspaceHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const CreateWorkspaceController = @import("../entrypoints/requests/CreateWorkspaceController.zig");

test "a committed workspace creation survives response queue backpressure" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var effects: CreateWorkspaceTestEffects = .{ .pane_id = try pane_module(17) };
    var handler: CreateWorkspaceHandlerType = .{
        .workspaces = &workspaces,
        .authority = effects.authority(),
        .geometry = effects.geometry(),
        .launcher = effects.launcher(),
        .attachment = effects.attachment(),
        .events = effects.publisher(),
    };
    var responses: ResponseQueueType = .{};
    const filler_location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(99) },
        .tab_id = try tab_module(99),
    };

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = filler_location,
            .position = 0,
        } });
    }

    var controller = CreateWorkspaceController.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.createWorkspace(.{
        .request_id = @enumFromInt(31),
        .name = "backend",
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

    try std.testing.expectEqual(@as(usize, 1), workspaces.reader().count());
    try std.testing.expectEqual(@as(usize, 1), effects.event_count);
    try std.testing.expectEqualStrings("backend", effects.last_event.?.nameSlice());
    try std.testing.expectEqualStrings("/work/new", workspaces.reader().workspacePath(effects.last_event.?.location.workspace).?);
    try std.testing.expectEqual(@as(usize, 1), effects.attachment_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
