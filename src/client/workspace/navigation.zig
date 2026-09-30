//! Bounded, disposable navigation bookmarks for workspace handoffs.

const core = @import("telar-core");
const data = @import("model");
const std = @import("std");

test "workspace bookmarks replace the last focused tab and pane" {
    var history: data.NavigationHistory = .{};
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(3) };
    history.remember(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(4) },
        .pane_id = @enumFromInt(5),
    });
    history.remember(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(7) },
        .pane_id = @enumFromInt(9),
    });

    const restored = history.find(workspace).?;
    try std.testing.expectEqual(@as(core.TabId, @enumFromInt(7)), restored.location.tab_id);
    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(9)), restored.pane_id);
    history.forget(workspace);
    try std.testing.expect(history.find(workspace) == null);
}

test "live layout retention stays bounded and the oldest tab makes room" {
    var layouts: data.SavedLayouts = .{};
    var layout: data.WorkspaceLayout = .{};
    const pane: core.PaneId = @enumFromInt(5);
    try layout.addRoot(pane);
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(1),
    };
    var saved: data.SavedLayout = .{ .location = location, .pane_id = pane, .workspace_active = true, .layout = layout };
    for (0..data.SavedLayouts.capacity) |index| {
        saved.location.tab_id = @enumFromInt(index + 1);
        layouts.retain(saved);
    }

    saved.location = location;
    try std.testing.expect(saved.layout.toggleFullscreen());
    layouts.retain(saved);
    try std.testing.expect(layouts.find(location).?.layout.isFullscreen());
    try std.testing.expectEqual(data.SavedLayouts.capacity, layouts.count);

    var oldest = location;
    oldest.tab_id = @enumFromInt(2);
    saved.location.workspace = .{ .workspace = @enumFromInt(4) };
    try std.testing.expectError(error.TooManySavedLayouts, layouts.remember(saved));
    layouts.retain(saved);
    try std.testing.expect(layouts.find(oldest) == null);
    try std.testing.expect(layouts.find(location) != null);
    try std.testing.expect(layouts.find(saved.location).?.layout.isFullscreen());
    layouts.forget(saved.location);
    try std.testing.expect(layouts.find(saved.location) == null);
    try std.testing.expectEqual(data.SavedLayouts.capacity - 1, layouts.count);
}

test "saved layouts are keyed by complete tab identity" {
    var layouts: data.SavedLayouts = .{};
    var first: data.WorkspaceLayout = .{};
    try first.addRoot(@enumFromInt(5));
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    try layouts.remember(.{
        .location = location,
        .pane_id = @enumFromInt(5),
        .workspace_active = true,
        .layout = first,
    });

    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(5)), layouts.find(location).?.pane_id);
    layouts.forget(location);
    try std.testing.expect(layouts.find(location) == null);
}
