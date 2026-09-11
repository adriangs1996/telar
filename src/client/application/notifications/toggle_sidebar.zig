//! Application use case for toggling one client's sidebar preference.

const sidebar_module = @import("../../layout/sidebar.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const ToggleSidebarEffectsCapture = @import("ToggleSidebarEffectsCapture.zig");
const ToggleSidebarHandler = @import("ToggleSidebarHandler.zig");
const VersionType = @import("../../model/Version.zig");
const ResizeSidebarHandler = @import("ResizeSidebarHandler.zig");

pub const Resize = union(enum) {
    exact: u16,
    direction: sidebar_module.Direction,
};

test "ToggleSidebarHandler commits before synchronizing client resources" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var effects: ToggleSidebarEffectsCapture = .{ .model = &model };
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var effects: ToggleSidebarEffectsCapture = .{
        .model = &model,
        .fail = true,
    };
    var handler: ToggleSidebarHandler = .{
        .model = &model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.SidebarSyncFailed, handler.execute());

    try std.testing.expect(!model.sidebarVisible());
    try std.testing.expectEqual(VersionType{ .chrome = 1 }, model.version());
    try std.testing.expect(effects.observed_commit);
}

test "ResizeSidebarHandler commits exact and stepped widths" {
    var model = ModelType.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .host_size = .{ .cols = 120, .rows = 24 },
    });
    defer model.deinit();
    var effects: ToggleSidebarEffectsCapture = .{ .model = &model };
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
