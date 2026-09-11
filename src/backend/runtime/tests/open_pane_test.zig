//! Vertical contract tests for the runtime open-pane flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const OpenPaneTestEffects = @import("OpenPaneTestEffects.zig");
const pane_module = @import("telar-core").pane;
const OpenPaneHandlerType = @import("../application/commands/OpenPaneHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const OpenPaneController = @import("../entrypoints/requests/OpenPaneController.zig");

test "a default pane launch survives response queue backpressure" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(1) },
        .tab_id = try tab_module(1),
    };
    var effects: OpenPaneTestEffects = .{ .launched = .{
        .key = .{ .id = try pane_module(17), .generation = 9 },
        .location = location,
    } };
    var handler: OpenPaneHandlerType = .{
        .workspaces = &workspaces,
        .panes = effects.panes(),
        .authority = effects.authority(),
        .geometry = effects.geometry(),
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

    var controller = OpenPaneController.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.openPane(.{
        .request_id = @enumFromInt(31),
        .target = .default,
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

    try std.testing.expect(workspaces.reader().contains(location));
    try std.testing.expectEqual(@as(usize, 2), effects.event_count);
    try std.testing.expectEqual(@as(usize, 1), effects.attachment_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
