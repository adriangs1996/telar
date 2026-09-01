//! Application use case for releasing every client authority tied to one
//! canonically retired pane.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const ReleasedResources = struct {
    copy_mode: bool,
    pane_paste: bool,
    reported_focus: bool,
};

pub const Effects = struct {
    context: *anyopaque,
    clear_graphics: *const fn (*anyopaque, schema.PaneId) void,
};

pub const ReleasePaneResourcesHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Releases exact model-owned authorities before clearing physical pane
    /// graphics. Repeated or unknown identities still clear stale graphics.
    ///
    /// ```zig
    /// const released = handler.execute(pane_id);
    /// ```
    pub fn execute(handler: *ReleasePaneResourcesHandler, pane_id: schema.PaneId) ReleasedResources {
        const released: ReleasedResources = .{
            .copy_mode = handler.model.releaseCopyMode(pane_id),
            .pane_paste = handler.model.releasePanePaste(pane_id),
            .reported_focus = handler.model.releaseReportedPaneFocus(pane_id),
        };

        handler.effects.clear_graphics(handler.effects.context, pane_id);

        return released;
    }
};

const EffectCapture = struct {
    model: ?*const client_model.Model = null,
    calls: usize = 0,
    pane_id: ?schema.PaneId = null,
    observed_released: bool = false,

    fn effects(capture: *EffectCapture) Effects {
        return .{ .context = capture, .clear_graphics = clearGraphics };
    }

    fn clearGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.pane_id = pane_id;

        if (capture.model) |model| {
            capture.observed_released = !model.copyModeActive() and
                !model.panePasteActive() and model.reportedPaneFocus() == null;
        }
    }
};

test "ReleasePaneResourcesHandler retires exact pane authorities before graphics" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;
    var capture: EffectCapture = .{ .model = &model };
    var handler: ReleasePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    const paste = handler.execute(pane_id);

    try std.testing.expectEqualDeep(ReleasedResources{
        .copy_mode = false,
        .pane_paste = true,
        .reported_focus = true,
    }, paste);
    try std.testing.expect(!model.panePasteActive());
    try std.testing.expect(model.reportedPaneFocus() == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(pane_id, capture.pane_id.?);
    try std.testing.expect(capture.observed_released);

    try std.testing.expect(model.enterCopyMode());
    _ = model.syncReportedPaneFocus().?;
    const copy = handler.execute(pane_id);

    try std.testing.expectEqualDeep(ReleasedResources{
        .copy_mode = true,
        .pane_paste = false,
        .reported_focus = true,
    }, copy);
    try std.testing.expect(!model.copyModeActive());
    try std.testing.expect(model.reportedPaneFocus() == null);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(capture.observed_released);
}

test "ReleasePaneResourcesHandler clears stale graphics for an unknown pane" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectCapture = .{ .model = &model };
    var handler: ReleasePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };
    const pane_id: schema.PaneId = @enumFromInt(9);

    try std.testing.expectEqualDeep(ReleasedResources{
        .copy_mode = false,
        .pane_paste = false,
        .reported_focus = false,
    }, handler.execute(pane_id));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(pane_id, capture.pane_id.?);
    try std.testing.expect(capture.observed_released);
}
