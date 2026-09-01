//! Application use case for resizing the focused pane in one client's layout.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model.zig");

const schema = core.schema;
const ui = core.ui;

pub const ResizePane = client_model.ResizePaneRequest;

pub const ResizeEffects = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, client_model.PaneGeometryChange) anyerror!void,
};

pub const ResizePaneHandler = struct {
    model: *client_model.Model,
    effects: ResizeEffects,

    /// Commits one split-edge change before delivering runtime geometry.
    /// Directions without a matching movable edge have no effects.
    ///
    /// ```zig
    /// const resize = try handler.execute(.{ .direction = .right, .area = area });
    /// ```
    pub fn execute(handler: *ResizePaneHandler, command: ResizePane) !?client_model.PaneGeometryChange {
        const resize = handler.model.resizePane(command) orelse return null;

        try handler.effects.deliver(handler.effects.context, resize);
        return resize;
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,
    first: schema.PaneId,
    area: ui.Rect = .{ .w = 101, .h = 41 },

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
        try model.workspace.bootstrap(first, location, .{ .cols = 101, .rows = 41 });
        try model.workspace.active().?.model.split(first, second, location, .horizontal, .{ .w = 101, .h = 41 });
        try std.testing.expect(model.workspace.active().?.model.focusPane(first));

        return .{
            .model = model,
            .location = location,
            .first = first,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    expected_focused: schema.PaneId,
    width_before: u16,
    calls: usize = 0,
    observed_commit: bool = false,
    resize: ?client_model.PaneGeometryChange = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) ResizeEffects {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(context: *anyopaque, resize: client_model.PaneGeometryChange) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const active = capture.model.workspace.active().?;
        capture.calls += 1;
        capture.resize = resize;
        capture.observed_commit = active.model.layout.focused() == capture.expected_focused and
            capture.model.version().panes == resize.panes_revision and
            active.model.contentSize(capture.expected_focused, resize.area).?.cols > capture.width_before and
            capture.model.version().panes == 1;

        if (capture.fail) {
            return error.ResizeSyncFailed;
        }
    }
};

test "ResizePaneHandler commits before delivering runtime geometry" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
        .width_before = width_before,
    };
    var handler: ResizePaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const resize = (try handler.execute(.{ .direction = .right, .area = testing.area })).?;

    try std.testing.expectEqualDeep(testing.location, resize.location);
    try std.testing.expectEqual(testing.first, resize.focused);
    try std.testing.expectEqualDeep(testing.area, resize.area);
    try std.testing.expectEqualDeep(resize, effects.resize.?);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "ResizePaneHandler suppresses absent layouts and directions without an edge" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
        .width_before = width_before,
    };
    var handler: ResizePaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expect((try handler.execute(.{ .direction = .up, .area = testing.area })) == null);
    testing.model.workspace.deinit();
    try std.testing.expect((try handler.execute(.{ .direction = .right, .area = testing.area })) == null);

    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ResizePaneHandler preserves the committed layout after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
        .width_before = width_before,
        .fail = true,
    };
    var handler: ResizePaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.ResizeSyncFailed, handler.execute(.{
        .direction = .right,
        .area = testing.area,
    }));

    try std.testing.expect(testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols > width_before);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
    try std.testing.expect(effects.observed_commit);
}
