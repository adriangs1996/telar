//! Application use case for changing one client's active tab.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const Target = client_model.TabSelectionTarget;

pub const SelectTab = struct {
    target: Target,
};

pub const SnapshotGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const SelectionEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, client_model.TabSelection) anyerror!void,
};

pub const SelectTabHandler = struct {
    model: *client_model.Model,
    snapshots: SnapshotGate,
    effects: SelectionEffects,

    /// Commits the active identity before synchronizing client resources.
    /// Missing, repeated and snapshot-blocked selections have no effects.
    ///
    /// ```zig
    /// const selection = try handler.execute(.{ .target = .{ .tab_id = tab_id } });
    /// ```
    pub fn execute(handler: *SelectTabHandler, command: SelectTab) !?client_model.TabSelection {
        if (handler.snapshots.pending(handler.snapshots.context)) {
            return null;
        }

        const selection = handler.model.selectTab(command.target) catch |err| switch (err) {
            error.NoActiveTab, error.TabNotFound => return null,
        } orelse return null;

        try handler.effects.apply(handler.effects.context, selection);
        return selection;
    }
};

const SnapshotGateCapture = struct {
    blocked: bool = false,

    fn port(capture: *SnapshotGateCapture) SnapshotGate {
        return .{ .context = capture, .pending = pending };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *SnapshotGateCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    expected: schema.TabLocation,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *EffectsCapture) SelectionEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, selection: client_model.TabSelection) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.observed_commit = std.meta.eql(capture.model.activeTabLocation(), capture.expected) and
            capture.model.version().active_tab == 1 and
            std.meta.eql(selection.selected, capture.expected);
        if (capture.fail) {
            return error.SelectionSyncFailed;
        }
    }
};

const TestingModel = struct {
    model: *client_model.Model,
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
        try std.testing.expect(model.workspace.select(first.tab_id));

        return .{ .model = model, .first = first, .second = second };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

test "SelectTabHandler commits a resolved target before synchronizing resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var snapshots: SnapshotGateCapture = .{};
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: SelectTabHandler = .{
        .model = testing.model,
        .snapshots = snapshots.port(),
        .effects = effects.port(),
    };

    const selection = (try handler.execute(.{ .target = .{ .position = 1 } })).?;

    try std.testing.expectEqualDeep(testing.first, selection.previous);
    try std.testing.expectEqualDeep(testing.second, selection.selected);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "SelectTabHandler suppresses blocked and ineffective selections" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var snapshots: SnapshotGateCapture = .{ .blocked = true };
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: SelectTabHandler = .{
        .model = testing.model,
        .snapshots = snapshots.port(),
        .effects = effects.port(),
    };

    try std.testing.expect((try handler.execute(.{ .target = .{ .offset = 1 } })) == null);
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
    snapshots.blocked = false;
    try std.testing.expect((try handler.execute(.{ .target = .{ .position = 0 } })) == null);
    try std.testing.expect((try handler.execute(.{ .target = .{ .position = 9 } })) == null);
    try std.testing.expect((try handler.execute(.{ .target = .{ .offset = 2 } })) == null);
    try std.testing.expect((try handler.execute(.{ .target = .{ .tab_id = @enumFromInt(9) } })) == null);
    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());

    testing.model.workspace.deinit();
    try std.testing.expect((try handler.execute(.{ .target = .{ .position = 0 } })) == null);
    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "SelectTabHandler preserves a committed selection after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var snapshots: SnapshotGateCapture = .{};
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected = testing.second,
        .fail = true,
    };
    var handler: SelectTabHandler = .{
        .model = testing.model,
        .snapshots = snapshots.port(),
        .effects = effects.port(),
    };

    try std.testing.expectError(
        error.SelectionSyncFailed,
        handler.execute(.{ .target = .{ .offset = 1 } }),
    );
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().active_tab);
    try std.testing.expect(effects.observed_commit);
}
