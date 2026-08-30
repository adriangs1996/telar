//! Owned domain events produced by workspace aggregate changes.
//!
//! Application handlers may hold an event while a wider runtime transaction
//! remains provisional and publish it only after that transaction commits.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

const OwnedTabLabel = struct {
    bytes: [schema.max_tab_label_bytes]u8 = undefined,
    len: u8,

    fn init(label: []const u8) !OwnedTabLabel {
        if (label.len == 0 or label.len > schema.max_tab_label_bytes) {
            return error.InvalidTabLabel;
        }

        var owned: OwnedTabLabel = .{ .len = @intCast(label.len) };
        @memcpy(owned.bytes[0..label.len], label);
        return owned;
    }

    fn slice(label: *const OwnedTabLabel) []const u8 {
        return label.bytes[0..label.len];
    }
};

fn OwnedWorkspaceName(comptime max_bytes: usize) type {
    return struct {
        const Self = @This();

        bytes: [max_bytes]u8 = undefined,
        len: u16,

        fn init(name: []const u8) !Self {
            if (name.len == 0 or name.len > max_bytes) {
                return error.InvalidWorkspaceName;
            }

            var owned: Self = .{ .len = @intCast(name.len) };
            @memcpy(owned.bytes[0..name.len], name);
            return owned;
        }

        fn slice(name: *const Self) []const u8 {
            return name.bytes[0..name.len];
        }
    };
}

const OwnedExplicitWorkspaceName = OwnedWorkspaceName(schema.max_tab_label_bytes);
const OwnedCreatedWorkspaceName = OwnedWorkspaceName(schema.max_workspace_name_bytes);

pub const TabCreated = struct {
    location: schema.TabLocation,
    position: u16,
    label: OwnedTabLabel,

    /// Creates an event that owns the canonical label of the new tab.
    ///
    /// ```zig
    /// const event = try TabCreated.init(location, 1, "logs");
    /// ```
    pub fn init(location: schema.TabLocation, position: u16, label: []const u8) !TabCreated {
        return .{
            .location = location,
            .position = position,
            .label = try .init(label),
        };
    }

    /// Returns the event-owned canonical tab label.
    ///
    /// ```zig
    /// const label = event.labelSlice();
    /// ```
    pub fn labelSlice(event: *const TabCreated) []const u8 {
        return event.label.slice();
    }
};

/// Committed disappearance of a tab from its workspace aggregate.
pub const TabRemoved = struct {
    location: schema.TabLocation,
    workspace_removed: bool,
    previous_workspace: ?schema.WorkspaceId = null,

    /// Creates a removal fact and rejects an impossible workspace handoff.
    /// A predecessor exists only when the removal also removed its workspace.
    ///
    /// ```zig
    /// const event = try TabRemoved.init(location, true, previous_workspace);
    /// ```
    pub fn init(location: schema.TabLocation, workspace_removed: bool, previous_workspace: ?schema.WorkspaceId) !TabRemoved {
        if (!workspace_removed and previous_workspace != null) {
            return error.UnexpectedPreviousWorkspace;
        }

        if (previous_workspace) |previous| {
            const removed_workspace = switch (location.workspace) {
                .workspace => |workspace_id| workspace_id,
                .worktree => return error.InvalidPreviousWorkspace,
            };

            if (previous == removed_workspace) {
                return error.InvalidPreviousWorkspace;
            }
        }

        return .{
            .location = location,
            .workspace_removed = workspace_removed,
            .previous_workspace = previous_workspace,
        };
    }
};

pub const TabRenamed = struct {
    location: schema.TabLocation,
    label: OwnedTabLabel,

    /// Validates and owns the canonical label carried by a tab rename event.
    /// The aggregate exposes this value only after committing the mutation.
    ///
    /// ```zig
    /// const event = try TabRenamed.init(location, "server");
    /// ```
    pub fn init(location: schema.TabLocation, label: []const u8) !TabRenamed {
        return .{
            .location = location,
            .label = try .init(label),
        };
    }

    /// Returns the event-owned canonical tab label.
    ///
    /// ```zig
    /// const label = event.labelSlice();
    /// ```
    pub fn labelSlice(event: *const TabRenamed) []const u8 {
        return event.label.slice();
    }
};

/// Committed position of a tab after a move request.
pub const TabMoved = struct {
    location: schema.TabLocation,
    position: u16,
};

pub const WorkspaceRenamed = struct {
    location: schema.WorkspaceLocation,
    name: OwnedExplicitWorkspaceName,

    /// Validates and owns the canonical name of a renamed workspace.
    ///
    /// ```zig
    /// const event = try WorkspaceRenamed.init(location, "backend");
    /// ```
    pub fn init(location: schema.WorkspaceLocation, name: []const u8) !WorkspaceRenamed {
        return .{ .location = location, .name = try .init(name) };
    }

    /// Returns the event-owned canonical workspace name.
    ///
    /// ```zig
    /// const name = event.nameSlice();
    /// ```
    pub fn nameSlice(event: *const WorkspaceRenamed) []const u8 {
        return event.name.slice();
    }
};

pub const WorkspaceCreated = struct {
    location: schema.TabLocation,
    name: OwnedCreatedWorkspaceName,

    /// Creates a committed workspace event that owns its canonical name.
    ///
    /// ```zig
    /// const event = try WorkspaceCreated.init(location, "backend");
    /// ```
    pub fn init(location: schema.TabLocation, name: []const u8) !WorkspaceCreated {
        return .{ .location = location, .name = try .init(name) };
    }

    /// Returns the event-owned canonical workspace name.
    ///
    /// ```zig
    /// const name = event.nameSlice();
    /// ```
    pub fn nameSlice(event: *const WorkspaceCreated) []const u8 {
        return event.name.slice();
    }
};

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
}

test "TabCreated owns its canonical label and position" {
    const location = try testingLocation();
    var source = [_]u8{ 'l', 'o', 'g', 's' };
    const event = try TabCreated.init(location, 2, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqual(@as(u16, 2), event.position);
    try std.testing.expectEqualStrings("logs", event.labelSlice());
}

test "TabCreated rejects labels it cannot own" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidTabLabel, TabCreated.init(location, 1, ""));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabCreated.init(location, 1, &oversized));
}

test "TabRemoved represents tab-only and whole-workspace removals" {
    const location = try testingLocation();
    const previous = try schema.id.workspace(2);
    const tab_only = try TabRemoved.init(location, false, null);
    const whole_workspace = try TabRemoved.init(location, true, previous);

    try std.testing.expectEqualDeep(location, tab_only.location);
    try std.testing.expect(!tab_only.workspace_removed);
    try std.testing.expect(tab_only.previous_workspace == null);
    try std.testing.expect(whole_workspace.workspace_removed);
    try std.testing.expectEqual(previous, whole_workspace.previous_workspace.?);
}

test "TabRemoved rejects impossible workspace handoffs" {
    const location = try testingLocation();
    const removed_workspace = switch (location.workspace) {
        .workspace => |workspace_id| workspace_id,
        .worktree => unreachable,
    };

    try std.testing.expectError(
        error.UnexpectedPreviousWorkspace,
        TabRemoved.init(location, false, try schema.id.workspace(2)),
    );
    try std.testing.expectError(
        error.InvalidPreviousWorkspace,
        TabRemoved.init(location, true, removed_workspace),
    );

    const worktree_location: schema.TabLocation = .{
        .workspace = .{ .worktree = try schema.id.worktree(4) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(
        error.InvalidPreviousWorkspace,
        TabRemoved.init(worktree_location, true, try schema.id.workspace(2)),
    );
}

test "TabRenamed owns its label independently of the source buffer" {
    const location = try testingLocation();
    var source = [_]u8{ 's', 'e', 'r', 'v', 'e', 'r' };
    const event = try TabRenamed.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("server", event.labelSlice());
}

test "TabRenamed rejects labels it cannot own" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, ""));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, &oversized));
}

test "TabMoved identifies the committed tab and canonical position" {
    const location = try testingLocation();
    const event: TabMoved = .{ .location = location, .position = 2 };

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqual(@as(u16, 2), event.position);
}

test "WorkspaceRenamed owns its canonical name" {
    const location: schema.WorkspaceLocation = .{ .workspace = try schema.id.workspace(3) };
    var source = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };
    const event = try WorkspaceRenamed.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("backend", event.nameSlice());
}

test "WorkspaceRenamed rejects names the aggregate cannot store" {
    const location: schema.WorkspaceLocation = .{ .workspace = try schema.id.workspace(3) };

    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceRenamed.init(location, ""));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceRenamed.init(location, &oversized));
}

test "WorkspaceCreated owns its canonical name and root tab identity" {
    const location = try testingLocation();
    var source = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };
    const event = try WorkspaceCreated.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("backend", event.nameSlice());
}

test "WorkspaceCreated owns path-derived names beyond the explicit label limit" {
    const location = try testingLocation();
    var source: [schema.max_tab_label_bytes + 1]u8 = @splat('p');
    const event = try WorkspaceCreated.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqual(@as(usize, schema.max_tab_label_bytes + 1), event.nameSlice().len);
    try std.testing.expect(std.mem.allEqual(u8, event.nameSlice(), 'p'));
}

test "WorkspaceCreated rejects names the aggregate cannot store" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceCreated.init(location, ""));

    const oversized: [schema.max_workspace_name_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceCreated.init(location, &oversized));
}
