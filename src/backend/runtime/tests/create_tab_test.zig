//! Vertical contract tests for the runtime create-tab flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const ClientCapture = @import("ClientCapture.zig");
const LauncherCapture = @import("LauncherCapture.zig");
const pane_module = @import("telar-core").pane;
const CreateTabTestEventCapture = @import("CreateTabTestEventCapture.zig");
const CreateTabHandlerType = @import("../application/commands/CreateTabHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const CreateTabController = @import("../entrypoints/requests/CreateTabController.zig");
const raw_module = @import("telar-core").raw;

test "a committed tab creation survives response queue backpressure" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    var client: ClientCapture = .{};
    var launcher: LauncherCapture = .{ .pane_id = try pane_module(17) };
    var events: CreateTabTestEventCapture = .{};
    var handler: CreateTabHandlerType = .{
        .workspaces = &workspaces,
        .authority = client.authority(),
        .launcher = launcher.port(),
        .attachment = client.attachment(),
        .events = events.publisher(),
    };
    var responses: ResponseQueueType = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = initial,
            .position = 0,
        } });
    }

    var requested_label = [_]u8{ 'l', 'o', 'g', 's' };
    var controller = CreateTabController.init(&responses, handler.executor());
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
    try std.testing.expectEqual(@as(u64, 3), raw_module(try workspaces.nextTabId()));
    try std.testing.expectEqual(@as(usize, 1), launcher.call_count);
    try std.testing.expectEqual(@as(usize, 1), client.attach_count);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualStrings("logs", events.last.?.labelSlice());
    try std.testing.expectEqualStrings("logs", workspaces.reader().tabLabel(events.last.?.location).?);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
