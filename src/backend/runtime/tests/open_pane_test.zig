//! Vertical contract tests for the runtime open-pane flow.

const std = @import("std");
const core = @import("telar-core");
const open_pane_commands = @import("../application/commands/open_pane.zig");
const open_pane_controller = @import("../entrypoints/requests/open_pane.zig");
const pane_mod = @import("../../pane/root.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

pub const schema = core.schema;

const Effects = @import("OpenPaneTestEffects.zig");

test "a default pane launch survives response queue backpressure" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    var effects: Effects = .{ .launched = .{
        .key = .{ .id = try schema.id.pane(17), .generation = 9 },
        .location = location,
    } };
    var handler: open_pane_commands.OpenPaneHandler = .{
        .workspaces = &workspaces,
        .panes = effects.panes(),
        .authority = effects.authority(),
        .geometry = effects.geometry(),
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

    var controller = open_pane_controller.Controller.init(&responses, handler.executor());
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
