//! Vertical contract tests for the runtime create-tab flow.

const std = @import("std");
const core = @import("telar-core");
const create_tab_commands = @import("../application/commands/create_tab.zig");
const create_tab_controller = @import("../entrypoints/requests/create_tab.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

pub const schema = core.schema;

const ClientCapture = @import("ClientCapture.zig");

const LauncherCapture = @import("LauncherCapture.zig");

const EventCapture = @import("CreateTabTestEventCapture.zig");

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
