//! Application commands for tab mutations.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const WorkspaceRepository = workspace_mod.Repository;

pub const RenameTab = struct {
    location: schema.TabLocation,
    /// Borrowed only for the synchronous `execute` call.
    label: []const u8,
};

pub const RenameTabResult = workspace_mod.TabRenamed;

/// Synchronous post-commit port. Implementations may retain the event value,
/// but the erased context only has to remain valid until `publish` returns.
pub const EventPublisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, workspace_mod.TabRenamed) void,
};

pub const RenameTabExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, RenameTab) anyerror!RenameTabResult,

    /// Executes a tab rename through the bound application handler.
    ///
    /// ```zig
    /// const renamed = try executor.execute(.{ .location = location, .label = "server" });
    /// ```
    pub fn execute(executor: RenameTabExecutor, command: RenameTab) !RenameTabResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const RenameTabHandler = struct {
    workspaces: *WorkspaceRepository,
    events: EventPublisher,

    /// Resolves the aggregate, commits its rename, then publishes the owned
    /// domain event. Failed commands neither mutate state nor publish events.
    ///
    /// ```zig
    /// const renamed = try handler.execute(.{ .location = location, .label = "server" });
    /// ```
    pub fn execute(handler: *RenameTabHandler, command: RenameTab) !RenameTabResult {
        const workspace = handler.workspaces.find(command.location.workspace) orelse return error.TabNotFound;
        const renamed = try workspace.renameTab(command.location.tab_id, command.label);

        handler.events.publish(handler.events.context, renamed);
        return renamed;
    }

    /// Erases the concrete handler behind the narrow command interface used
    /// by request controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *RenameTabHandler) RenameTabExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: RenameTab) !RenameTabResult {
        const handler: *RenameTabHandler = @ptrCast(@alignCast(context));
        return handler.execute(command);
    }
};

const EventCapture = struct {
    reader: workspace_mod.Reader,
    count: usize = 0,
    last: ?workspace_mod.TabRenamed = null,
    observed_committed_state: bool = false,

    fn publisher(capture: *EventCapture) EventPublisher {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, event: workspace_mod.TabRenamed) void {
        const capture: *EventCapture = @ptrCast(@alignCast(context));
        const committed_label = capture.reader.tabLabel(event.location) orelse return;

        capture.count += 1;
        capture.last = event;
        capture.observed_committed_state = std.mem.eql(u8, committed_label, event.labelSlice());
    }
};

fn testingRepository(state: *workspace_mod.State) WorkspaceRepository {
    return WorkspaceRepository.init(state, std.testing.allocator);
}

test "RenameTabHandler commits before publishing one owned event" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };
    const executor = handler.executor();
    var requested_label = [_]u8{ 's', 'e', 'r', 'v', 'e', 'r' };

    const renamed = try executor.execute(.{
        .location = location,
        .label = &requested_label,
    });
    @memset(&requested_label, 'x');

    try std.testing.expectEqualStrings("server", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.observed_committed_state);
    try std.testing.expectEqualDeep(location, capture.last.?.location);
    try std.testing.expectEqualStrings("server", capture.last.?.labelSlice());
    try std.testing.expectEqualStrings("server", renamed.labelSlice());
}

test "RenameTabHandler rejects invalid targets and labels without effects" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };

    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .location = location,
        .label = "",
    }));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .location = location,
        .label = &oversized,
    }));

    var missing_tab = location;
    missing_tab.tab_id = try schema.id.tab(999);
    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_tab,
        .label = "missing",
    }));

    const missing_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(999) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_workspace,
        .label = "missing",
    }));

    try std.testing.expectEqualStrings("main", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expect(capture.last == null);
}
