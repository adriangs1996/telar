//! Application policy for restoring the visible active tab after a local
//! workspace-handoff effect fails before departure commits.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");
const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");

const schema = core.schema;

pub const Effects = struct {
    context: *anyopaque,
    show_pane_graphics: *const fn (*anyopaque, schema.PaneId) anyerror!void,
};

pub const Outcome = enum {
    no_active_tab,
    snapshot_coalesced,
    snapshot_requested,
};

pub const RestoreWorkspaceHandoffHandler = struct {
    effects: Effects,
    snapshots: tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler,

    /// Restores active-pane graphics in captured order and requests one
    /// canonical tab snapshot unless recovery is already pending.
    ///
    /// ```zig
    /// _ = try handler.execute(model);
    /// ```
    pub fn execute(handler: *RestoreWorkspaceHandoffHandler, model: *const client_model.Model) !Outcome {
        const location = model.activeTabLocation() orelse return .no_active_tab;
        const plan = try model.planTabDetachment(location);

        for (plan.slice()) |pane| {
            try handler.effects.show_pane_graphics(handler.effects.context, pane.pane_id);
        }

        return switch (try handler.snapshots.execute(location)) {
            .coalesced => .snapshot_coalesced,
            .requested => .snapshot_requested,
        };
    }
};

const Event = union(enum) {
    show_graphics: schema.PaneId,
    snapshot_pending,
    request_snapshot: schema.TabLocation,
};

const Failure = enum {
    none,
    sibling_graphics,
    snapshot,
};

const TestingModel = struct {
    model: *client_model.Model,
    active: schema.TabLocation,
    root: schema.PaneId,
    sibling: schema.PaneId,
    inactive_pane: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const active: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const inactive: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const root: schema.PaneId = @enumFromInt(1);
        const sibling: schema.PaneId = @enumFromInt(2);
        const inactive_pane: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(root, active, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(root, sibling, active, .horizontal, .{ .w = 40, .h = 10 });
        _ = try model.workspace.addCreated(.{
            .location = inactive,
            .position = 1,
            .label = "logs",
            .root_pane_id = inactive_pane,
        }, .{ .cols = 40, .rows = 10 });
        if (!model.workspace.select(active.tab_id)) {
            return error.ActiveTabNotRestored;
        }

        return .{
            .model = model,
            .active = active,
            .root = root,
            .sibling = sibling,
            .inactive_pane = inactive_pane,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const Capture = struct {
    sibling: schema.PaneId,
    pending: bool = false,
    failure: Failure = .none,
    events: [4]Event = undefined,
    event_count: usize = 0,

    fn handler(capture: *Capture) RestoreWorkspaceHandoffHandler {
        return .{
            .effects = .{
                .context = capture,
                .show_pane_graphics = showPaneGraphics,
            },
            .snapshots = .{ .effects = .{
                .context = capture,
                .pending = tabSnapshotPending,
                .request = requestTabSnapshot,
            } },
        };
    }

    fn showPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.{ .show_graphics = pane_id });
        if (capture.failure == .sibling_graphics and pane_id == capture.sibling) {
            return error.GraphicsVisibilityFailed;
        }
    }

    fn tabSnapshotPending(context: *anyopaque) bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.snapshot_pending);

        return capture.pending;
    }

    fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.append(.{ .request_snapshot = location });
        if (capture.failure == .snapshot) {
            return error.SnapshotRequestFailed;
        }
    }

    fn append(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const Capture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

test "RestoreWorkspaceHandoffHandler shows only active panes before snapshot recovery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{ .sibling = testing.sibling };
    var handler = capture.handler();
    const version = testing.model.version();

    const outcome = try handler.execute(testing.model);

    try std.testing.expectEqual(Outcome.snapshot_requested, outcome);
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .show_graphics = testing.root },
        .{ .show_graphics = testing.sibling },
        .snapshot_pending,
        .{ .request_snapshot = testing.active },
    }, capture.eventSlice());
    for (capture.eventSlice()) |event| switch (event) {
        .show_graphics => |pane_id| try std.testing.expect(pane_id != testing.inactive_pane),
        .snapshot_pending, .request_snapshot => {},
    };
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "RestoreWorkspaceHandoffHandler coalesces only after restoring graphics" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .sibling = testing.sibling,
        .pending = true,
    };
    var handler = capture.handler();

    const outcome = try handler.execute(testing.model);

    try std.testing.expectEqual(Outcome.snapshot_coalesced, outcome);
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .show_graphics = testing.root },
        .{ .show_graphics = testing.sibling },
        .snapshot_pending,
    }, capture.eventSlice());
}

test "RestoreWorkspaceHandoffHandler ignores an already empty model" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    _ = testing.model.departWorkspace();
    var capture: Capture = .{ .sibling = testing.sibling };
    var handler = capture.handler();

    const outcome = try handler.execute(testing.model);

    try std.testing.expectEqual(Outcome.no_active_tab, outcome);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "RestoreWorkspaceHandoffHandler preserves completed stages on failure" {
    var graphics = try TestingModel.init();
    defer graphics.deinit();
    var graphics_capture: Capture = .{
        .sibling = graphics.sibling,
        .failure = .sibling_graphics,
    };
    var graphics_handler = graphics_capture.handler();

    try std.testing.expectError(error.GraphicsVisibilityFailed, graphics_handler.execute(graphics.model));
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .show_graphics = graphics.root },
        .{ .show_graphics = graphics.sibling },
    }, graphics_capture.eventSlice());

    var snapshot = try TestingModel.init();
    defer snapshot.deinit();
    var snapshot_capture: Capture = .{
        .sibling = snapshot.sibling,
        .failure = .snapshot,
    };
    var snapshot_handler = snapshot_capture.handler();

    try std.testing.expectError(error.SnapshotRequestFailed, snapshot_handler.execute(snapshot.model));
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .show_graphics = snapshot.root },
        .{ .show_graphics = snapshot.sibling },
        .snapshot_pending,
        .{ .request_snapshot = snapshot.active },
    }, snapshot_capture.eventSlice());
}
