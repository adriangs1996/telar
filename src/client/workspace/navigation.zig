//! Bounded, disposable navigation bookmarks for workspace handoffs.

const History = @import("History.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const std = @import("std");
const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const Layouts = @import("Layouts.zig");
const LayoutType = @import("WorkspaceLayout.zig");
const TabLocationType = @import("telar-core").TabLocation;
const SavedLayout = @import("SavedLayout.zig");
const max_client_layout_tabs_module = @import("telar-core").max_client_layout_tabs;

test "workspace bookmarks replace the last focused tab and pane" {
    var history: History = .{};
    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(3) };
    history.remember(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(4) },
        .pane_id = @enumFromInt(5),
    });
    history.remember(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(7) },
        .pane_id = @enumFromInt(9),
    });

    const restored = history.find(workspace).?;
    try std.testing.expectEqual(@as(TabIdType, @enumFromInt(7)), restored.location.tab_id);
    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(9)), restored.pane_id);
    history.forget(workspace);
    try std.testing.expect(history.find(workspace) == null);
}

test "live layout retention stays bounded and replaces existing tabs before eviction" {
    var layouts: Layouts = .{};
    var layout: LayoutType = .{};
    const pane: PaneIdType = @enumFromInt(5);
    try layout.addRoot(pane);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(1),
    };
    var saved: SavedLayout = .{ .location = location, .pane_id = pane, .workspace_active = true, .layout = layout };
    for (0..max_client_layout_tabs_module) |index| {
        saved.location.tab_id = @enumFromInt(index + 1);
        layouts.retain(saved);
    }

    saved.location = location;
    try std.testing.expect(saved.layout.toggleFullscreen());
    layouts.retain(saved);
    try std.testing.expect(layouts.find(location).?.layout.isFullscreen());
    try std.testing.expectEqual(@as(usize, 0), layouts.eviction_index);
    saved.location.workspace = .{ .workspace = @enumFromInt(4) };
    try std.testing.expectError(error.TooManySavedLayouts, layouts.remember(saved));
    layouts.retain(saved);
    try std.testing.expectEqual(@as(usize, 1), layouts.eviction_index);
    try std.testing.expect(layouts.find(location) == null);
    try std.testing.expect(layouts.find(saved.location).?.layout.isFullscreen());
    layouts.forget(saved.location);
    layouts.retain(saved);
    try std.testing.expectEqual(@as(usize, 1), layouts.eviction_index);
    try std.testing.expect(layouts.find(saved.location) != null);
}

test "saved layouts are keyed by complete tab identity" {
    var layouts: Layouts = .{};
    var first: LayoutType = .{};
    try first.addRoot(@enumFromInt(5));
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    try layouts.remember(.{
        .location = location,
        .pane_id = @enumFromInt(5),
        .workspace_active = true,
        .layout = first,
    });

    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(5)), layouts.find(location).?.pane_id);
    layouts.forget(location);
    try std.testing.expect(layouts.find(location) == null);
}
