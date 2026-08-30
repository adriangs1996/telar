//! Vertical contract tests for the runtime open-pane flow.

const std = @import("std");
const core = @import("telar-core");
const open_pane_commands = @import("commands/open_pane.zig");
const open_pane_controller = @import("controllers/open_pane.zig");
const pane_mod = @import("../pane/root.zig");
const response_queue = @import("response_queue.zig");
const workspace_mod = @import("../workspace/root.zig");

const schema = core.schema;

const Effects = struct {
    launched: pane_mod.PaneLaunched,
    event_count: usize = 0,
    attachment_count: usize = 0,

    fn panes(effects: *Effects) open_pane_commands.Panes {
        return .{
            .context = effects,
            .find = find,
            .first = first,
            .launch = launch,
            .prepare_view = prepareView,
            .attach = attach,
        };
    }

    fn authority(effects: *Effects) open_pane_commands.LaunchAuthority {
        return .{ .context = effects, .prepare = prepare };
    }

    fn geometry(effects: *Effects) open_pane_commands.GeometryLease {
        return .{
            .context = effects,
            .acquire = acquire,
            .release = release,
        };
    }

    fn publisher(effects: *Effects) open_pane_commands.EventPublisher {
        return .{ .context = effects, .publish = publish };
    }

    fn find(_: *anyopaque, _: schema.PaneId) ?pane_mod.PaneLaunched {
        return null;
    }

    fn first(_: *anyopaque, _: schema.TabLocation) ?pane_mod.PaneLaunched {
        return null;
    }

    fn launch(context: *anyopaque, _: open_pane_commands.LaunchPane) !pane_mod.PaneLaunched {
        const effects: *Effects = @ptrCast(@alignCast(context));
        return effects.launched;
    }

    fn prepareView(_: *anyopaque, _: open_pane_commands.PrepareView) !void {}

    fn attach(context: *anyopaque, _: pane_mod.PaneLaunched) !void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.attachment_count += 1;
    }

    fn prepare(_: *anyopaque, _: open_pane_commands.PrepareLaunch) ![]const u8 {
        return "/work/new";
    }

    fn acquire(_: *anyopaque, _: schema.WorkspaceLocation) bool {
        return true;
    }

    fn release(_: *anyopaque, _: schema.WorkspaceLocation) void {
        unreachable;
    }

    fn publish(context: *anyopaque, _: open_pane_commands.RuntimeEvent) void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.event_count += 1;
    }
};

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
    var responses: response_queue.ResponseQueue = .{};

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
