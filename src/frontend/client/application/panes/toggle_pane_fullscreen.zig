//! Application use case for toggling one client's focused pane fullscreen.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;
const ui = core.ui;

pub const TogglePaneFullscreen = client_model.TogglePaneFullscreenRequest;

pub const FullscreenEffects = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, client_model.PaneGeometryChange) anyerror!void,
};

pub const TogglePaneFullscreenHandler = struct {
    model: *client_model.Model,
    effects: FullscreenEffects,

    /// Commits fullscreen state before delivering graphics and runtime
    /// geometry. Tabs with fewer than two panes have no effects.
    ///
    /// ```zig
    /// const change = try handler.execute(.{ .area = area });
    /// ```
    pub fn execute(handler: *TogglePaneFullscreenHandler, command: TogglePaneFullscreen) !?client_model.PaneGeometryChange {
        const change = handler.model.togglePaneFullscreen(command) orelse return null;

        try handler.effects.deliver(handler.effects.context, change);
        return change;
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,
    first: schema.PaneId,
    second: schema.PaneId,
    area: ui.Rect = .{ .w = 80, .h = 24 },

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const first: schema.PaneId = @enumFromInt(1);
        const second: schema.PaneId = @enumFromInt(2);
        try model.workspace.bootstrap(first, location, .{ .cols = 80, .rows = 24 });
        try model.workspace.active().?.model.split(first, second, location, .horizontal, .{ .w = 80, .h = 24 });
        try std.testing.expect(model.workspace.active().?.model.focusPane(first));

        return .{
            .model = model,
            .location = location,
            .first = first,
            .second = second,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    expected_focused: schema.PaneId,
    calls: usize = 0,
    observed_commit: bool = false,
    change: ?client_model.PaneGeometryChange = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) FullscreenEffects {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(context: *anyopaque, change: client_model.PaneGeometryChange) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const active = capture.model.workspace.activeConst().?;
        capture.calls += 1;
        capture.change = change;
        capture.observed_commit = active.model.layout.focused() == capture.expected_focused and
            active.model.layout.isFullscreen() == change.fullscreen and
            capture.model.version().panes == change.panes_revision and
            capture.model.version().panes == 1;

        if (capture.fail) {
            return error.FullscreenSyncFailed;
        }
    }
};

test "TogglePaneFullscreenHandler commits before delivering geometry" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
    };
    var handler: TogglePaneFullscreenHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const change = (try handler.execute(.{ .area = testing.area })).?;

    try std.testing.expectEqualDeep(testing.location, change.location);
    try std.testing.expectEqual(testing.first, change.focused);
    try std.testing.expectEqualDeep(testing.area, change.area);
    try std.testing.expect(change.fullscreen);
    try std.testing.expectEqualDeep(change, effects.change.?);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "TogglePaneFullscreenHandler suppresses single-pane and absent layouts" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
    };
    var handler: TogglePaneFullscreenHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expect(testing.model.workspace.active().?.model.removePane(testing.second));
    try std.testing.expect((try handler.execute(.{ .area = testing.area })) == null);
    testing.model.workspace.deinit();
    try std.testing.expect((try handler.execute(.{ .area = testing.area })) == null);

    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "TogglePaneFullscreenHandler preserves the commit after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
        .fail = true,
    };
    var handler: TogglePaneFullscreenHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.FullscreenSyncFailed, handler.execute(.{ .area = testing.area }));

    try std.testing.expect(testing.model.workspace.activeConst().?.model.layout.isFullscreen());
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
    try std.testing.expect(effects.observed_commit);
}
