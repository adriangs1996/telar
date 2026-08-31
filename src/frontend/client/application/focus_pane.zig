//! Application use case for changing focus inside one client's active tab.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;
const ui = core.ui;

pub const Target = client_model.PaneFocusTarget;
pub const FocusPane = client_model.PaneFocusRequest;

pub const FocusEffects = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, client_model.PaneFocus, ui.Rect) anyerror!void,
};

pub const FocusPaneHandler = struct {
    model: *client_model.Model,
    effects: FocusEffects,

    /// Commits one focus change before delivering it to active-pane resources.
    /// A rejected or repeated target has no effects.
    ///
    /// ```zig
    /// const focus = try handler.execute(.{ .target = .{ .pane_id = pane_id }, .area = area });
    /// ```
    pub fn execute(handler: *FocusPaneHandler, command: FocusPane) !?client_model.PaneFocus {
        const focus = handler.model.focusPane(command) orelse return null;

        try handler.effects.deliver(handler.effects.context, focus, command.area);
        return focus;
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
    expected: schema.PaneId,
    calls: usize = 0,
    observed_commit: bool = false,
    focus: ?client_model.PaneFocus = null,
    area: ?ui.Rect = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) FocusEffects {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(context: *anyopaque, focus: client_model.PaneFocus, area: ui.Rect) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.focus = focus;
        capture.area = area;
        capture.observed_commit = capture.model.workspace.activeConst().?.model.layout.focused() == capture.expected and
            capture.model.version().panes == 1;

        if (capture.fail) {
            return error.FocusSyncFailed;
        }
    }
};

test "FocusPaneHandler commits before delivering active-pane resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    try std.testing.expect(testing.model.workspace.active().?.model.toggleFullscreen());
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.first };
    var handler: FocusPaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const focus = (try handler.execute(.{
        .target = .{ .direction = .left },
        .area = testing.area,
    })).?;

    try std.testing.expectEqual(testing.second, focus.previous);
    try std.testing.expectEqual(testing.first, focus.focused);
    try std.testing.expect(focus.geometry_changed);
    try std.testing.expectEqual(@as(u64, 1), focus.panes_revision);
    try std.testing.expectEqualDeep(testing.area, effects.area.?);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "FocusPaneHandler suppresses repeated missing and directionless targets" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: FocusPaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expect((try handler.execute(.{
        .target = .{ .pane_id = testing.second },
        .area = testing.area,
    })) == null);
    try std.testing.expect((try handler.execute(.{
        .target = .{ .pane_id = @enumFromInt(9) },
        .area = testing.area,
    })) == null);
    try std.testing.expect((try handler.execute(.{
        .target = .{ .direction = .right },
        .area = testing.area,
    })) == null);

    testing.model.workspace.deinit();
    try std.testing.expect((try handler.execute(.{
        .target = .{ .pane_id = testing.first },
        .area = testing.area,
    })) == null);
    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "FocusPaneHandler preserves committed focus after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected = testing.first,
        .fail = true,
    };
    var handler: FocusPaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.FocusSyncFailed, handler.execute(.{
        .target = .{ .pane_id = testing.first },
        .area = testing.area,
    }));

    try std.testing.expectEqual(testing.first, testing.model.workspace.activeConst().?.model.layout.focused().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
    try std.testing.expect(effects.observed_commit);
}
