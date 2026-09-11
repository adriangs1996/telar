const Workspace = @This();
const source_namespace = @import("workspace_support.zig");
const Tab = @import("Tab.zig");
const std = @import("std");
const events = @import("events.zig");
pub const Init = struct {
    id: source_namespace.schema.WorkspaceId,
    path: []u8,
    default_tab_id: source_namespace.schema.TabId,
    explicit_name: ?[]const u8 = null,
};

id: source_namespace.schema.WorkspaceId,
path: []u8,
explicit_name: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
explicit_name_len: u8 = 0,
tabs: [source_namespace.max_tabs_per_workspace]?Tab = [_]?Tab{null} ** source_namespace.max_tabs_per_workspace,
tab_count: usize = 0,
git_branch: [source_namespace.schema.max_git_branch_bytes]u8 = undefined,
git_branch_len: u8 = 0,
git_dirty: bool = false,
git_checked_at_ms: i64 = 0,

pub fn init(options: Init) !Workspace {
    if (options.path.len == 0 or options.path.len > source_namespace.schema.max_cwd_bytes or std.mem.indexOfScalar(u8, options.path, 0) != null) {
        return error.InvalidWorkspacePath;
    }

    var workspace: Workspace = .{
        .id = options.id,
        .path = options.path,
    };

    if (options.explicit_name) |name_value| {
        _ = try workspace.rename(name_value);
    }

    _ = try workspace.appendTab(try Tab.init(options.default_tab_id, "main"));
    return workspace;
}

pub fn deinit(workspace: *Workspace, gpa: std.mem.Allocator) void {
    gpa.free(workspace.path);
}

pub fn name(workspace: *const Workspace) []const u8 {
    if (workspace.explicit_name_len != 0) {
        return workspace.explicit_name[0..workspace.explicit_name_len];
    }

    const basename = std.fs.path.basename(workspace.path);
    return if (basename.len == 0) workspace.path else basename;
}

pub fn pathSlice(workspace: *const Workspace) []const u8 {
    return workspace.path;
}

pub fn gitBranch(workspace: *const Workspace) []const u8 {
    return workspace.git_branch[0..workspace.git_branch_len];
}

/// Commits observation time and visible Git state together.
/// Example: `_ = workspace.completeGitProbe(observation);`.
pub fn completeGitProbe(workspace: *Workspace, observation: @import("git_observation.zig").Observation) bool {
    workspace.git_checked_at_ms = observation.checked_at_ms;
    return workspace.applyGitStatus(observation.branch, observation.dirty);
}

/// Stores one git observation and reports whether the projection changed.
///
/// ```zig
/// if (workspace.applyGitStatus("main", true)) publishListChange();
/// ```
pub fn applyGitStatus(workspace: *Workspace, branch: []const u8, dirty: bool) bool {
    const bounded = branch[0..@min(branch.len, workspace.git_branch.len)];
    const changed = !std.mem.eql(u8, workspace.gitBranch(), bounded) or workspace.git_dirty != dirty;
    @memcpy(workspace.git_branch[0..bounded.len], bounded);
    workspace.git_branch_len = @intCast(bounded.len);
    workspace.git_dirty = dirty;
    return changed;
}

/// The user-chosen name, or null when the name derives from the path.
///
/// ```zig
/// const explicit = workspace.explicitName() orelse "";
/// ```
pub fn explicitName(workspace: *const Workspace) ?[]const u8 {
    if (workspace.explicit_name_len == 0) {
        return null;
    }
    return workspace.explicit_name[0..workspace.explicit_name_len];
}

/// Renames the aggregate and returns an event that owns its canonical
/// name. Repository revision and publication remain outside the aggregate.
///
/// ```zig
/// const renamed = try workspace.rename("backend");
/// ```
pub fn rename(workspace: *Workspace, name_value: []const u8) !events.WorkspaceRenamed {
    if (name_value.len == 0 or name_value.len > workspace.explicit_name.len) {
        return error.InvalidWorkspaceName;
    }

    @memcpy(workspace.explicit_name[0..name_value.len], name_value);
    workspace.explicit_name_len = @intCast(name_value.len);

    return events.WorkspaceRenamed.init(
        .{ .workspace = workspace.id },
        workspace.name(),
    ) catch unreachable;
}

pub fn defaultTab(workspace: *const Workspace) source_namespace.schema.TabId {
    std.debug.assert(workspace.tab_count != 0);
    return workspace.tabs[0].?.id;
}

pub fn tabCount(workspace: *const Workspace) usize {
    return workspace.tab_count;
}

pub fn containsTab(workspace: *const Workspace, tab_id: source_namespace.schema.TabId) bool {
    return workspace.findTabConst(tab_id) != null;
}

/// Adds one tab after validating its label and returns an owned event for
/// the caller's transaction boundary. An empty requested label is replaced
/// with the stable `tab <id>` default used by the runtime.
///
/// ```zig
/// const created = try workspace.createTab(tab_id, "logs");
/// ```
pub fn createTab(workspace: *Workspace, tab_id: source_namespace.schema.TabId, requested_label: []const u8) !events.TabCreated {
    if (workspace.tab_count == workspace.tabs.len) {
        return error.TabLimitReached;
    }

    var generated_label: [source_namespace.schema.max_tab_label_bytes]u8 = undefined;
    const label = if (requested_label.len == 0)
        try std.fmt.bufPrint(&generated_label, "tab {d}", .{source_namespace.schema.id.raw(tab_id)})
    else
        requested_label;
    const position = try workspace.appendTab(try Tab.init(tab_id, label));

    return events.TabCreated.init(.{
        .workspace = .{ .workspace = workspace.id },
        .tab_id = tab_id,
    }, position, label) catch unreachable;
}

/// Renames one tab and returns an owned event describing the committed
/// change. Repository revisions and external projections remain outside
/// the aggregate.
///
/// ```zig
/// const renamed = try workspace.renameTab(tab_id, "server");
/// ```
pub fn renameTab(workspace: *Workspace, tab_id: source_namespace.schema.TabId, label: []const u8) !events.TabRenamed {
    const tab = workspace.findTab(tab_id) orelse return error.TabNotFound;
    try tab.rename(label);

    return events.TabRenamed.init(.{
        .workspace = .{ .workspace = workspace.id },
        .tab_id = tab.id,
    }, tab.labelSlice()) catch unreachable;
}

pub fn removeTab(workspace: *Workspace, tab_id: source_namespace.schema.TabId) bool {
    const index = workspace.tabIndex(tab_id) orelse return false;
    var cursor = index;

    while (cursor + 1 < workspace.tab_count) : (cursor += 1) {
        workspace.tabs[cursor] = workspace.tabs[cursor + 1];
    }

    workspace.tab_count -= 1;
    workspace.tabs[workspace.tab_count] = null;
    return true;
}

/// Reorders a tab and returns the committed position as a domain event.
/// Moving beyond either edge succeeds at the existing edge position.
///
/// ```zig
/// const moved = workspace.moveTab(tab_id, .previous) orelse return;
/// ```
pub fn moveTab(workspace: *Workspace, tab_id: source_namespace.schema.TabId, direction: source_namespace.schema.TabMoveDirection) ?events.TabMoved {
    const index = workspace.tabIndex(tab_id) orelse return null;
    const target = switch (direction) {
        .previous => if (index == 0) index else index - 1,
        .next => if (index + 1 == workspace.tab_count) index else index + 1,
    };

    if (target != index) {
        std.mem.swap(?Tab, &workspace.tabs[index], &workspace.tabs[target]);
    }

    return .{
        .location = .{
            .workspace = .{ .workspace = workspace.id },
            .tab_id = tab_id,
        },
        .position = @intCast(target),
    };
}

pub fn tabLabel(workspace: *const Workspace, tab_id: source_namespace.schema.TabId) ?[]const u8 {
    const tab = workspace.findTabConst(tab_id) orelse return null;
    return tab.labelSlice();
}

/// Writes an ordered, allocation-free tab projection into caller storage.
/// Labels borrow the aggregate and remain valid until the next mutation.
///
/// ```zig
/// var storage: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
/// const tabs = workspace.writeDescriptors(&storage);
/// ```
pub fn writeDescriptors(workspace: *const Workspace, output: *[source_namespace.max_tabs_per_workspace]source_namespace.schema.TabDescriptor) []source_namespace.schema.TabDescriptor {
    for (&workspace.tabs, 0..) |*slot, index| {
        if (index == workspace.tab_count) {
            break;
        }

        const tab = if (slot.*) |*value| value else unreachable;
        output[index] = .{
            .tab_id = tab.id,
            .position = @intCast(index),
            .pane_count = 0,
            .label = tab.labelSlice(),
        };
    }

    return output[0..workspace.tab_count];
}

fn findTab(workspace: *Workspace, tab_id: source_namespace.schema.TabId) ?*Tab {
    for (&workspace.tabs) |*slot| {
        const tab = if (slot.*) |*value| value else continue;

        if (tab.id == tab_id) {
            return tab;
        }
    }

    return null;
}

fn findTabConst(workspace: *const Workspace, tab_id: source_namespace.schema.TabId) ?*const Tab {
    for (&workspace.tabs) |*slot| {
        const tab = if (slot.*) |*value| value else continue;

        if (tab.id == tab_id) {
            return tab;
        }
    }

    return null;
}

fn tabIndex(workspace: *const Workspace, tab_id: source_namespace.schema.TabId) ?usize {
    for (workspace.tabs[0..workspace.tab_count], 0..) |slot, index| {
        if (slot != null and slot.?.id == tab_id) {
            return index;
        }
    }

    return null;
}

fn appendTab(workspace: *Workspace, tab: Tab) !u16 {
    if (workspace.tab_count == workspace.tabs.len) {
        return error.TabLimitReached;
    }

    const index = workspace.tab_count;
    workspace.tabs[index] = tab;
    workspace.tab_count += 1;
    return @intCast(index);
}
