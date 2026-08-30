//! Vertical contract tests for the runtime workspace rename flow.

const std = @import("std");
const core = @import("telar-core");
const rename_workspace_commands = @import("commands/rename_workspace.zig");
const rename_workspace_controller = @import("controllers/rename_workspace.zig");
const response_queue = @import("response_queue.zig");
const workspace_mod = @import("../workspace/root.zig");

const schema = core.schema;

const EventCapture = struct {
    count: usize = 0,
    last: ?workspace_mod.WorkspaceRenamed = null,

    fn publisher(capture: *EventCapture) rename_workspace_commands.EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.WorkspaceRenamed) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        capture.count += 1;
        capture.last = event;
    }
};

test "a committed workspace rename survives response queue backpressure" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    const revision = workspaces.reader().revision();
    var events: EventCapture = .{};
    var handler: rename_workspace_commands.RenameWorkspaceHandler = .{
        .workspaces = &workspaces,
        .events = events.publisher(),
    };
    var responses: response_queue.ResponseQueue = .{};
    const tab_location: schema.TabLocation = .{
        .workspace = location,
        .tab_id = workspaces.reader().defaultTab(location).?,
    };

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = tab_location,
            .position = 0,
        } });
    }

    var requested_name = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };
    var controller = rename_workspace_controller.Controller.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.renameWorkspace(.{
        .request_id = @enumFromInt(31),
        .workspace = location,
        .name = &requested_name,
    }));
    @memset(&requested_name, 'x');

    try std.testing.expectEqualStrings("backend", workspaces.reader().workspaceName(location).?);
    try std.testing.expect(workspaces.reader().revision() != revision);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualDeep(location, events.last.?.location);
    try std.testing.expectEqualStrings("backend", events.last.?.nameSlice());
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
