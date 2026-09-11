//! Bounded, disposable navigation bookmarks for workspace handoffs.

const std = @import("std");
const core = @import("telar-core");
const layout_mod = @import("layout_support.zig");

pub const schema = core.schema;

pub const Bookmark = @import("Bookmark.zig");

pub const SavedLayout = @import("SavedLayout.zig");

pub const Layouts = @import("Layouts.zig");

pub const History = @import("History.zig");

test "workspace bookmarks replace the last focused tab and pane" {
    var history: History = .{};
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(3) };
    history.remember(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(4) },
        .pane_id = @enumFromInt(5),
    });
    history.remember(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(7) },
        .pane_id = @enumFromInt(9),
    });

    const restored = history.find(workspace).?;
    try std.testing.expectEqual(@as(schema.TabId, @enumFromInt(7)), restored.location.tab_id);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(9)), restored.pane_id);
    history.forget(workspace);
    try std.testing.expect(history.find(workspace) == null);
}

test "live layout retention stays bounded and replaces existing tabs before eviction" {
    var layouts: Layouts = .{};
    var layout: layout_mod.Layout = .{};
    const pane: schema.PaneId = @enumFromInt(5);
    try layout.addRoot(pane);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(1),
    };
    var saved: SavedLayout = .{ .location = location, .pane_id = pane, .workspace_active = true, .layout = layout };
    for (0..schema.max_client_layout_tabs) |index| {
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
    var first: layout_mod.Layout = .{};
    try first.addRoot(@enumFromInt(5));
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(4),
    };
    try layouts.remember(.{
        .location = location,
        .pane_id = @enumFromInt(5),
        .workspace_active = true,
        .layout = first,
    });

    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(5)), layouts.find(location).?.pane_id);
    layouts.forget(location);
    try std.testing.expect(layouts.find(location) == null);
}
