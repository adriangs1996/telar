//! Application use case for applying one canonical tab snapshot.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;
const ui = core.ui;

pub const Effects = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, *const client_model.TabReconciliation) anyerror!void,
};

pub const ApplyTabSnapshotHandler = struct {
    model: *client_model.Model,
    area: ui.Rect,
    effects: Effects,

    /// Commits canonical pane membership before delivering client resources.
    /// Model failures have no effects; effect failures preserve the commit.
    ///
    /// ```zig
    /// try handler.execute(snapshot);
    /// ```
    pub fn execute(handler: *ApplyTabSnapshotHandler, snapshot: client_model.TabSnapshot) !void {
        const reconciliation = try handler.model.reconcileTab(snapshot, handler.area);
        try handler.effects.deliver(handler.effects.context, &reconciliation);
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    expected_pane: schema.PaneId,
    calls: usize = 0,
    observed_commit: bool = false,
    active: bool = false,
    panes_changed: bool = false,
    fail: bool = false,

    fn port(capture: *EffectsCapture) Effects {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(context: *anyopaque, reconciliation: *const client_model.TabReconciliation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.active = reconciliation.active;
        capture.panes_changed = reconciliation.panes_changed;
        capture.observed_commit = capture.model.workspace.findPane(capture.expected_pane) != null and
            capture.model.version().workspace == reconciliation.workspace_revision and
            capture.model.version().tabs == reconciliation.tabs_revision and
            capture.model.version().active_tab == reconciliation.active_tab_revision and
            capture.model.version().panes == reconciliation.panes_revision;

        if (capture.fail) {
            return error.ReconciliationSyncFailed;
        }
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,
    root_pane: schema.PaneId,
    discovered_pane: schema.PaneId,
    pane_ids: [2]schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const root_pane: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(.{ .pane_id = root_pane, .location = location, .size = .{ .cols = 20, .rows = 5 } });

        const discovered_pane: schema.PaneId = @enumFromInt(2);

        return .{
            .model = model,
            .location = location,
            .root_pane = root_pane,
            .discovered_pane = discovered_pane,
            .pane_ids = .{ root_pane, discovered_pane },
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn snapshot(testing: *const TestingModel) client_model.TabSnapshot {
        return .{
            .location = testing.location,
            .panes = &testing.pane_ids,
        };
    }
};

test "ApplyTabSnapshotHandler commits before delivering client resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected_pane = testing.discovered_pane,
    };
    var handler: ApplyTabSnapshotHandler = .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .effects = capture.port(),
    };
    try handler.execute(testing.snapshot());

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(capture.active);
    try std.testing.expect(capture.panes_changed);
}

test "ApplyTabSnapshotHandler still runs resource effects for a canonical no-op" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected_pane = testing.discovered_pane,
    };
    var handler: ApplyTabSnapshotHandler = .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .effects = capture.port(),
    };
    const snapshot = testing.snapshot();
    try handler.execute(snapshot);
    const committed_version = testing.model.version();

    try handler.execute(snapshot);

    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(!capture.panes_changed);
    try std.testing.expectEqualDeep(committed_version, testing.model.version());
}

test "ApplyTabSnapshotHandler rejects model failures before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected_pane = testing.discovered_pane,
    };
    var handler: ApplyTabSnapshotHandler = .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .effects = capture.port(),
    };
    const snapshot: client_model.TabSnapshot = .{
        .location = .{
            .workspace = testing.location.workspace,
            .tab_id = @enumFromInt(9),
        },
        .panes = &.{testing.root_pane},
    };

    try std.testing.expectError(error.UnexpectedTab, handler.execute(snapshot));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ApplyTabSnapshotHandler preserves a committed snapshot after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected_pane = testing.discovered_pane,
        .fail = true,
    };
    var handler: ApplyTabSnapshotHandler = .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .effects = capture.port(),
    };
    try std.testing.expectError(error.ReconciliationSyncFailed, handler.execute(testing.snapshot()));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(testing.model.workspace.findPane(testing.discovered_pane) != null);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
}
