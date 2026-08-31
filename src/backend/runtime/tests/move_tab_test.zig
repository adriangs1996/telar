//! Vertical contract tests for the runtime move-tab flow.

const std = @import("std");
const core = @import("telar-core");
const move_tab_commands = @import("../commands/move_tab.zig");
const move_tab_controller = @import("../controllers/move_tab.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;

const EventCapture = struct {
    count: usize = 0,
    last: ?workspace_mod.TabMoved = null,

    fn publisher(capture: *EventCapture) move_tab_commands.EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.TabMoved) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        capture.count += 1;
        capture.last = event;
    }
};

fn appendTestingTab(workspaces: *workspace_mod.Repository, workspace: schema.WorkspaceLocation) !schema.TabLocation {
    const aggregate = workspaces.find(workspace) orelse return error.WorkspaceNotFound;
    const tab_id = try workspaces.nextTabId();
    const created = try aggregate.createTab(tab_id, "logs");
    workspaces.recordTabCreated(tab_id);
    return created.location;
}

test "a committed tab move survives response queue backpressure" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const initial = (try workspaces.ensure("/work/project")).location;
    const moved_location = try appendTestingTab(&workspaces, initial.workspace);
    const revision = workspaces.reader().revision();
    var events: EventCapture = .{};
    var handler: move_tab_commands.MoveTabHandler = .{
        .workspaces = &workspaces,
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

    var controller = move_tab_controller.Controller.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.moveTab(.{
        .request_id = @enumFromInt(31),
        .location = moved_location,
        .direction = .previous,
    }));

    try std.testing.expectEqual(moved_location.tab_id, workspaces.reader().defaultTab(initial.workspace).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualDeep(moved_location, events.last.?.location);
    try std.testing.expectEqual(@as(u16, 0), events.last.?.position);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
