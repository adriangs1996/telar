//! Application use case for applying one canonical workspace snapshot.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const ReconciliationEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, *const client_model.WorkspaceReconciliation) anyerror!void,
};

pub const ApplyWorkspaceSnapshotHandler = struct {
    model: *client_model.Model,
    effects: ReconciliationEffects,

    /// Commits a canonical snapshot before reconciling client resources.
    /// Model failures have no effects; effect failures preserve the commit.
    ///
    /// ```zig
    /// try handler.execute(snapshot);
    /// ```
    pub fn execute(handler: *ApplyWorkspaceSnapshotHandler, snapshot: schema.WorkspaceSnapshotView) !void {
        const reconciliation = try handler.model.reconcileWorkspace(snapshot);
        try handler.effects.apply(handler.effects.context, &reconciliation);
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    removed_tabs: usize = 0,
    removed_panes: usize = 0,
    active_changed: bool = false,
    fail: bool = false,

    fn port(capture: *EffectsCapture) ReconciliationEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, reconciliation: *const client_model.WorkspaceReconciliation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const version = capture.model.version();
        capture.calls += 1;
        capture.removed_tabs = reconciliation.removed_tabs.slice().len;
        capture.removed_panes = reconciliation.removed_panes.slice().len;
        capture.active_changed = reconciliation.active_tab_changed;
        capture.observed_commit = std.mem.eql(u8, capture.model.workspace.workspaceName(), "renamed") and
            capture.model.workspace.count == 1 and
            version.workspace == 1 and
            version.tabs == 1 and
            version.active_tab == 1;

        if (capture.fail) {
            return error.ReconciliationSyncFailed;
        }
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    workspace: schema.WorkspaceLocation,
    first: schema.TabLocation,
    second: schema.TabLocation,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const first: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const second: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
        _ = try model.workspace.addCreated(.{
            .location = second,
            .position = 1,
            .label = "logs",
            .root_pane_id = @enumFromInt(2),
        }, .{ .cols = 20, .rows = 5 });

        return .{
            .model = model,
            .workspace = workspace,
            .first = first,
            .second = second,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn snapshot(testing: *const TestingModel, buffer: []u8) !schema.WorkspaceSnapshotView {
        const encoded = try schema.encodeWorkspaceSnapshot(buffer, .{
            .request_id = @enumFromInt(7),
            .workspace = testing.workspace,
            .name = "renamed",
            .tabs = &.{
                .{ .tab_id = testing.first.tab_id, .position = 0, .pane_count = 1, .label = "main" },
            },
        });

        return (try schema.decodeServer(encoded)).workspace_snapshot;
    }
};

test "ApplyWorkspaceSnapshotHandler commits before reconciling client resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: ApplyWorkspaceSnapshotHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    var buffer: [512]u8 = undefined;

    try handler.execute(try testing.snapshot(&buffer));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.removed_tabs);
    try std.testing.expectEqual(@as(usize, 1), capture.removed_panes);
    try std.testing.expect(capture.active_changed);
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
}

test "ApplyWorkspaceSnapshotHandler still runs resource effects for a canonical no-op" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: ApplyWorkspaceSnapshotHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    var buffer: [512]u8 = undefined;
    const snapshot = try testing.snapshot(&buffer);
    try handler.execute(snapshot);
    const committed_version = testing.model.version();

    try handler.execute(snapshot);

    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), capture.removed_tabs);
    try std.testing.expectEqual(@as(usize, 0), capture.removed_panes);
    try std.testing.expect(!capture.active_changed);
    try std.testing.expectEqualDeep(committed_version, testing.model.version());
}

test "ApplyWorkspaceSnapshotHandler rejects model failures before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: ApplyWorkspaceSnapshotHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    var buffer: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(7),
        .workspace = .{ .workspace = @enumFromInt(9) },
        .name = "wrong",
        .tabs = &.{
            .{ .tab_id = testing.first.tab_id, .position = 0, .pane_count = 1, .label = "main" },
        },
    });
    const snapshot = (try schema.decodeServer(encoded)).workspace_snapshot;

    try std.testing.expectError(error.UnexpectedWorkspace, handler.execute(snapshot));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ApplyWorkspaceSnapshotHandler preserves a committed snapshot after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .fail = true };
    var handler: ApplyWorkspaceSnapshotHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    var buffer: [512]u8 = undefined;

    try std.testing.expectError(error.ReconciliationSyncFailed, handler.execute(try testing.snapshot(&buffer)));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualStrings("renamed", testing.model.workspace.workspaceName());
    try std.testing.expectEqual(@as(usize, 1), testing.model.workspace.count);
}
