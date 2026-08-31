//! Vertical contract tests for the runtime tab rename flow.

const std = @import("std");
const core = @import("telar-core");
const rename_tab_commands = @import("../commands/rename_tab.zig");
const rename_tab_controller = @import("../controllers/rename_tab.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;

const EventCapture = struct {
    count: usize = 0,
    last: ?workspace_mod.TabRenamed = null,

    fn publisher(capture: *EventCapture) rename_tab_commands.EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.TabRenamed) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        capture.count += 1;
        capture.last = event;
    }
};

test "a committed rename survives response queue backpressure" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var events: EventCapture = .{};
    var handler: rename_tab_commands.RenameTabHandler = .{
        .workspaces = &workspaces,
        .events = events.publisher(),
    };
    var responses: delivery_mod.ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    var controller = rename_tab_controller.Controller.init(&responses, handler.executor());
    try std.testing.expectError(error.ResponseQueueFull, controller.renameTab(.{
        .request_id = @enumFromInt(31),
        .location = location,
        .label = "server",
    }));

    try std.testing.expectEqualStrings("server", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(@as(usize, 1), events.count);
    try std.testing.expectEqualDeep(location, events.last.?.location);
    try std.testing.expectEqualStrings("server", events.last.?.labelSlice());
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
