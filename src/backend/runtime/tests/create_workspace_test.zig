//! Vertical contract tests for the runtime create-workspace flow.

const std = @import("std");
const core = @import("telar-core");
const create_workspace_commands = @import("../application/commands/create_workspace.zig");
const create_workspace_controller = @import("../entrypoints/requests/create_workspace.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

pub const schema = core.schema;

const Effects = @import("CreateWorkspaceTestEffects.zig");

test "a committed workspace creation survives response queue backpressure" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var effects: Effects = .{ .pane_id = try schema.id.pane(17) };
    var handler: create_workspace_commands.CreateWorkspaceHandler = .{
        .workspaces = &workspaces,
        .authority = effects.authority(),
        .geometry = effects.geometry(),
        .launcher = effects.launcher(),
        .attachment = effects.attachment(),
        .events = effects.publisher(),
    };
    var responses: delivery_mod.ResponseQueue = .{};
    const filler_location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(99) },
        .tab_id = try schema.id.tab(99),
    };

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = filler_location,
            .position = 0,
        } });
    }

    var controller = create_workspace_controller.Controller.init(&responses, handler.executor());
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
