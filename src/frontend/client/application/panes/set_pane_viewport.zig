//! Application use case for changing one pane's client-owned viewport.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const SetPaneViewport = client_model.PaneViewportCommand;

pub const PaneViewportEffects = struct {
    context: *anyopaque,
    sync: *const fn (*anyopaque, client_model.PaneViewportChange) anyerror!void,
};

pub const SetPaneViewportHandler = struct {
    model: *client_model.Model,
    effects: PaneViewportEffects,

    /// Commits a bounded client viewport before synchronizing graphics and
    /// the runtime. Invalid targets and repeated offsets have no effects.
    ///
    /// ```zig
    /// const change = try handler.execute(command) orelse return;
    /// ```
    pub fn execute(handler: *SetPaneViewportHandler, command: SetPaneViewport) !?client_model.PaneViewportChange {
        const change = handler.model.setPaneViewport(command) orelse return null;

        try handler.effects.sync(handler.effects.context, change);
        return change;
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    pane_id: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 10, .rows = 5 } });
        model.workspace.findPane(pane_id).?.scroll = .{ .total_rows = 20, .offset = 10 };

        return .{ .model = model, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    change: ?client_model.PaneViewportChange = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) PaneViewportEffects {
        return .{ .context = capture, .sync = sync };
    }

    fn sync(context: *anyopaque, change: client_model.PaneViewportChange) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const pane = capture.model.workspace.activeConst().?.model.findConst(change.pane_id).?;
        capture.calls += 1;
        capture.change = change;
        capture.observed_commit = pane.scroll.offset == change.offset and
            capture.model.version().viewport == change.viewport_revision;

        if (capture.fail) {
            return error.ViewportSyncFailed;
        }
    }
};

test "SetPaneViewportHandler commits before synchronizing client resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: SetPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const change = (try handler.execute(.{
        .pane_id = testing.pane_id,
        .target = .{ .relative = -4 },
    })).?;

    try std.testing.expectEqual(@as(u32, 6), change.offset);
    try std.testing.expect(!change.at_bottom);
    try std.testing.expectEqual(@as(u64, 1), change.viewport_revision);
    try std.testing.expectEqualDeep(change, capture.change.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
}

test "SetPaneViewportHandler suppresses repeated and unavailable targets" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: SetPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute(.{
        .pane_id = testing.pane_id,
        .target = .{ .absolute = 10 },
    })) == null);
    try std.testing.expect((try handler.execute(.{
        .pane_id = @enumFromInt(9),
        .target = .bottom,
    })) == null);

    testing.model.workspace.findPane(testing.pane_id).?.attached = false;
    try std.testing.expect((try handler.execute(.{
        .pane_id = testing.pane_id,
        .target = .bottom,
    })) == null);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "SetPaneViewportHandler preserves the committed viewport after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .fail = true };
    var handler: SetPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.ViewportSyncFailed, handler.execute(.{
        .pane_id = testing.pane_id,
        .target = .bottom,
    }));

    try std.testing.expectEqual(@as(u32, 15), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    try std.testing.expectEqual(client_model.Version{ .viewport = 1 }, testing.model.version());
    try std.testing.expect(capture.observed_commit);
}
