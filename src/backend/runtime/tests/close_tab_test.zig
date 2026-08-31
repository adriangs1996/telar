//! Vertical contract tests for the runtime close-tab flow.

const std = @import("std");
const core = @import("telar-core");
const close_tab_commands = @import("../application/commands/close_tab.zig");
const close_tab_controller = @import("../entrypoints/requests/close_tab.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;

const PaneCapture = struct {
    close_count: usize = 0,
    last_location: ?schema.TabLocation = null,

    fn port(capture: *PaneCapture) close_tab_commands.PaneCloser {
        return .{ .context = capture, .close_all = closeAll };
    }

    fn closeAll(context: *anyopaque, location: schema.TabLocation) void {
        const capture: *PaneCapture = @ptrCast(@alignCast(context));
        capture.close_count += 1;
        capture.last_location = location;
    }
};

const EventCapture = struct {
    count: usize = 0,
    last: ?workspace_mod.TabRemoved = null,

    fn publisher(capture: *EventCapture) close_tab_commands.EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.TabRemoved) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        capture.count += 1;
        capture.last = event;
    }
};

test "a committed tab removal survives response queue backpressure" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const first = (try workspaces.ensure("/work/first")).location;
    const removed_location = (try workspaces.ensure("/work/second")).location;
    const first_workspace = switch (first.workspace) {
        .workspace => |workspace_id| workspace_id,
        .worktree => unreachable,
    };
    const revision = workspaces.reader().revision();
    var panes: PaneCapture = .{};
    var events: EventCapture = .{};
    var handler: close_tab_commands.CloseTabHandler = .{
        .workspaces = &workspaces,
        .panes = panes.port(),
        .events = events.publisher(),
    };
    var responses: delivery_mod.ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = first,
            .position = 0,
        } });
    }

    var controller = close_tab_controller.Controller.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.closeTab(.{
        .request_id = @enumFromInt(31),
        .location = removed_location,
    }));

    try std.testing.expect(!workspaces.reader().containsWorkspace(removed_location.workspace));
    try std.testing.expectEqual(@as(usize, 1), workspaces.reader().count());
    try std.testing.expect(workspaces.reader().revision() != revision);
    try std.testing.expectEqual(@as(usize, 1), panes.close_count);
    try std.testing.expectEqualDeep(removed_location, panes.last_location.?);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualDeep(removed_location, events.last.?.location);
    try std.testing.expect(events.last.?.workspace_removed);
    try std.testing.expectEqual(first_workspace, events.last.?.previous_workspace.?);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
