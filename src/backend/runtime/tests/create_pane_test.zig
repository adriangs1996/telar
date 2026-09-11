//! Vertical contract tests for the runtime create-pane flow.

const std = @import("std");
const core = @import("telar-core");
const create_pane_commands = @import("../application/commands/create_pane.zig");
const create_pane_controller = @import("../entrypoints/requests/create_pane.zig");
const pane_mod = @import("../../pane/root.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

pub const schema = core.schema;

const Effects = @import("CreatePaneTestEffects.zig");

test "a committed pane launch survives response queue backpressure" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var effects: Effects = .{ .launched = .{
        .key = .{ .id = try schema.id.pane(17), .generation = 9 },
        .location = location,
    } };
    var handler: create_pane_commands.CreatePaneHandler = .{
        .workspaces = workspaces.reader(),
        .panes = effects.panes(),
        .authority = effects.authority(),
        .launcher = effects.launcher(),
        .attachment = effects.attachment(),
        .events = effects.publisher(),
    };
    var responses: delivery_mod.ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    var controller = create_pane_controller.Controller.init(&responses, handler.executor());
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
