//! Vertical contract tests for the runtime create-tab flow.

const std = @import("std");
const core = @import("telar-core");
const create_tab_commands = @import("../commands/create_tab.zig");
const create_tab_controller = @import("../controllers/create_tab.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;

const ClientCapture = struct {
    attach_count: usize = 0,

    fn authority(capture: *ClientCapture) create_tab_commands.LaunchAuthority {
        return .{
            .context = capture,
            .prepare = prepareLaunch,
        };
    }

    fn attachment(capture: *ClientCapture) create_tab_commands.PaneAttachment {
        return .{ .context = capture, .attach = attach };
    }

    fn prepareLaunch(_: *anyopaque, _: create_tab_commands.PrepareLaunch) ![]const u8 {
        return "/prepared";
    }

    fn attach(context: *anyopaque, _: create_tab_commands.LaunchedPane) !void {
        const capture: *ClientCapture = @ptrCast(@alignCast(context));
        capture.attach_count += 1;
    }
};

const LauncherCapture = struct {
    pane_id: schema.PaneId,
    call_count: usize = 0,

    fn port(capture: *LauncherCapture) create_tab_commands.PaneLauncher {
        return .{ .context = capture, .launch = launch };
    }

    fn launch(context: *anyopaque, _: create_tab_commands.LaunchPane) !create_tab_commands.LaunchedPane {
        const capture: *LauncherCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        return .{ .id = capture.pane_id };
    }
};

const EventCapture = struct {
    count: usize = 0,
    last: ?workspace_mod.TabCreated = null,

    fn publisher(capture: *EventCapture) create_tab_commands.EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.TabCreated) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        capture.count += 1;
        capture.last = event;
    }
};

test "a committed tab creation survives response queue backpressure" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    var client: ClientCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try schema.id.pane(17) };
    var events: EventCapture = .{};
    var handler: create_tab_commands.CreateTabHandler = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };
    var responses: delivery_mod.ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = initial,
            .position = 0,
        } });
    }

    var requested_label = [_]u8{ 'l', 'o', 'g', 's' };
    var controller = create_tab_controller.Controller.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.createTab(.{
        .request_id = @enumFromInt(31),
        .workspace = initial.workspace,
        .label = &requested_label,
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
    @memset(&requested_label, 'x');

    try std.testing.expectEqual(@as(usize, 2), workspaces.reader().totalTabs());
    try std.testing.expectEqual(@as(u64, 3), schema.id.raw(try workspaces.nextTabId()));
    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 1), client.attach_count);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualStrings("logs", events.last.?.labelSlice());
    try std.testing.expectEqualStrings("logs", workspaces.reader().tabLabel(events.last.?.location).?);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
