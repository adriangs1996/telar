//! Application use case for applying one canonical tab snapshot.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;
const ui = core.ui;

pub const ReconciliationEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, *const client_model.TabReconciliation) anyerror!void,
};

pub const ApplyTabSnapshotHandler = struct {
    model: *client_model.Model,
    area: ui.Rect,
    effects: ReconciliationEffects,

    /// Commits canonical pane membership before repairing client resources.
    /// Model failures have no effects; effect failures preserve the commit.
    ///
    /// ```zig
    /// try handler.execute(snapshot);
    /// ```
    pub fn execute(handler: *ApplyTabSnapshotHandler, snapshot: schema.TabSnapshotView) !void {
        const reconciliation = try handler.model.reconcileTab(snapshot, handler.area);
        try handler.effects.apply(handler.effects.context, &reconciliation);
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

    fn port(capture: *EffectsCapture) ReconciliationEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, reconciliation: *const client_model.TabReconciliation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.active = reconciliation.active;
        capture.panes_changed = reconciliation.panes_changed;
        capture.observed_commit = capture.model.workspace.findPane(capture.expected_pane) != null and
            capture.model.version().panes == 1;

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
        try model.workspace.bootstrap(root_pane, location, .{ .cols = 20, .rows = 5 });

        return .{
            .model = model,
            .location = location,
            .root_pane = root_pane,
            .discovered_pane = @enumFromInt(2),
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn snapshot(testing: *const TestingModel, buffer: []u8) !schema.TabSnapshotView {
        const encoded = try schema.encodeTabSnapshot(buffer, .{
            .request_id = @enumFromInt(7),
            .location = testing.location,
            .panes = &.{
                .{ .pane_id = testing.root_pane, .lifecycle = .running },
                .{ .pane_id = testing.discovered_pane, .lifecycle = .running },
            },
        });

        return (try schema.decodeServer(encoded)).tab_snapshot;
    }
};

test "ApplyTabSnapshotHandler commits before reconciling client resources" {
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
    var buffer: [256]u8 = undefined;

    try handler.execute(try testing.snapshot(&buffer));

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
    var buffer: [256]u8 = undefined;
    const snapshot = try testing.snapshot(&buffer);
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
    var buffer: [256]u8 = undefined;
    const encoded = try schema.encodeTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(7),
        .location = .{
            .workspace = testing.location.workspace,
            .tab_id = @enumFromInt(9),
        },
        .panes = &.{.{ .pane_id = testing.root_pane, .lifecycle = .running }},
    });
    const snapshot = (try schema.decodeServer(encoded)).tab_snapshot;

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
    var buffer: [256]u8 = undefined;

    try std.testing.expectError(error.ReconciliationSyncFailed, handler.execute(try testing.snapshot(&buffer)));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(testing.model.workspace.findPane(testing.discovered_pane) != null);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
}
