//! Vertical contract tests for the runtime create-pane flow.

const std = @import("std");
const core = @import("telar-core");
const create_pane_commands = @import("../commands/create_pane.zig");
const create_pane_controller = @import("../controllers/create_pane.zig");
const pane_mod = @import("../../pane/root.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;

const Effects = struct {
    launched: pane_mod.PaneLaunched,
    attachment_count: usize = 0,
    event_count: usize = 0,

    fn panes(effects: *Effects) create_pane_commands.TabPanes {
        return .{ .context = effects, .has_running = hasRunning };
    }

    fn authority(effects: *Effects) create_pane_commands.LaunchAuthority {
        return .{ .context = effects, .prepare = prepare };
    }

    fn launcher(effects: *Effects) create_pane_commands.PaneLauncher {
        return .{ .context = effects, .launch = launch };
    }

    fn attachment(effects: *Effects) create_pane_commands.PaneAttachment {
        return .{ .context = effects, .attach = attach };
    }

    fn publisher(effects: *Effects) create_pane_commands.EventPublisher {
        return .{ .context = effects, .publish = publish };
    }

    fn hasRunning(_: *anyopaque, _: schema.TabLocation) bool {
        return true;
    }

    fn prepare(_: *anyopaque, _: create_pane_commands.PrepareLaunch) ![]const u8 {
        return "/work/project";
    }

    fn launch(context: *anyopaque, _: create_pane_commands.LaunchPane) !pane_mod.PaneLaunched {
        const effects: *Effects = @ptrCast(@alignCast(context));
        return effects.launched;
    }

    fn attach(context: *anyopaque, _: pane_mod.PaneLaunched) !void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.attachment_count += 1;
    }

    fn publish(context: *anyopaque, _: pane_mod.PaneLaunched) void {
        const effects: *Effects = @ptrCast(@alignCast(context));
        effects.event_count += 1;
    }
};

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
