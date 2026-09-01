//! Application use case for toggling one client's sidebar preference.

const std = @import("std");
const client_model = @import("../../model/root.zig");

pub const SidebarEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, client_model.SidebarLayout) anyerror!void,
};

pub const ToggleSidebarHandler = struct {
    model: *client_model.Model,
    effects: SidebarEffects,

    /// Commits the sidebar preference before synchronizing its disposable
    /// projection and pane geometry.
    ///
    /// ```zig
    /// const change = try handler.execute();
    /// ```
    pub fn execute(handler: *ToggleSidebarHandler) !client_model.SidebarLayout {
        const change = handler.model.toggleSidebar();

        try handler.effects.apply(handler.effects.context, change);
        return change;
    }
};

pub const Resize = union(enum) {
    exact: u16,
    direction: @import("../../../ui/root.zig").sidebar.Direction,
};

pub const ResizeSidebarHandler = struct {
    model: *client_model.Model,
    effects: SidebarEffects,

    /// Commits one exact or stepped width before synchronizing geometry.
    ///
    /// ```zig
    /// _ = try handler.execute(.{ .exact = 73 });
    /// ```
    pub fn execute(handler: *ResizeSidebarHandler, resize: Resize) !?client_model.SidebarLayout {
        const change = switch (resize) {
            .exact => |width| handler.model.setSidebarWidth(width),
            .direction => |direction| handler.model.stepSidebarWidth(direction),
        } orelse return null;

        try handler.effects.apply(handler.effects.context, change);
        return change;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    change: ?client_model.SidebarLayout = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) SidebarEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, change: client_model.SidebarLayout) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.change = change;
        capture.observed_commit = capture.model.sidebarVisible() == change.visible and
            capture.model.version().chrome == change.chrome_revision;

        if (capture.fail) {
            return error.SidebarSyncFailed;
        }
    }
};

test "ToggleSidebarHandler commits before synchronizing client resources" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var effects: EffectsCapture = .{ .model = &model };
    var handler: ToggleSidebarHandler = .{
        .model = &model,
        .effects = effects.port(),
    };

    const hidden = try handler.execute();

    try std.testing.expect(!hidden.visible);
    try std.testing.expectEqualDeep(hidden, effects.change.?);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);

    const shown = try handler.execute();

    try std.testing.expect(shown.visible);
    try std.testing.expectEqual(@as(u64, 2), shown.chrome_revision);
    try std.testing.expectEqual(@as(usize, 2), effects.calls);
}

test "ToggleSidebarHandler preserves the committed preference after effect failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var effects: EffectsCapture = .{
        .model = &model,
        .fail = true,
    };
    var handler: ToggleSidebarHandler = .{
        .model = &model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.SidebarSyncFailed, handler.execute());

    try std.testing.expect(!model.sidebarVisible());
    try std.testing.expectEqual(client_model.Version{ .chrome = 1 }, model.version());
    try std.testing.expect(effects.observed_commit);
}

test "ResizeSidebarHandler commits exact and stepped widths" {
    var model = client_model.Model.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .host_size = .{ .cols = 120, .rows = 24 },
    });
    defer model.deinit();
    var effects: EffectsCapture = .{ .model = &model };
    var handler: ResizeSidebarHandler = .{
        .model = &model,
        .effects = effects.port(),
    };

    const exact = (try handler.execute(.{ .exact = 73 })).?;
    try std.testing.expectEqual(@as(u16, 73), exact.width);
    try std.testing.expectEqual(@as(u16, 73), model.sidebarWidth());

    const narrower = (try handler.execute(.{ .direction = .narrower })).?;
    try std.testing.expectEqual(@as(u16, 71), narrower.width);
    try std.testing.expectEqual(@as(usize, 2), effects.calls);
}
