const Reader = @This();
const source_namespace = @import("repository_support.zig");
const std = @import("std");
const workspace_mod = @import("workspace_support.zig");
const DescriptorSnapshot = @import("DescriptorSnapshot.zig");
const state_mod = @import("state_support.zig");
state: *const source_namespace.State,

pub fn init(state: *const source_namespace.State) Reader {
    return .{ .state = state };
}

pub fn count(reader: Reader) usize {
    return reader.state.count;
}

pub fn revision(reader: Reader) u64 {
    return reader.state.revision;
}

pub fn containsWorkspace(reader: Reader, location: source_namespace.schema.WorkspaceLocation) bool {
    return reader.find(location) != null;
}

/// Returns the default tab location for the first aggregate with `path`.
///
/// ```zig
/// const location = reader.locationByPath("/work/telar") orelse return;
/// ```
pub fn locationByPath(reader: Reader, path: []const u8) ?source_namespace.schema.TabLocation {
    const workspace = reader.findByPath(path) orelse return null;
    return .{
        .workspace = .{ .workspace = workspace.id },
        .tab_id = workspace.defaultTab(),
    };
}

fn find(reader: Reader, location: source_namespace.schema.WorkspaceLocation) ?*const source_namespace.Workspace {
    const workspace_id = source_namespace.workspaceId(location) orelse return null;

    for (&reader.state.items) |*slot| {
        const workspace = if (slot.*) |*value| value else continue;

        if (workspace.id == workspace_id) {
            return workspace;
        }
    }

    return null;
}

fn findByPath(reader: Reader, path: []const u8) ?*const source_namespace.Workspace {
    for (&reader.state.items) |*slot| {
        const workspace = if (slot.*) |*value| value else continue;

        if (std.mem.eql(u8, workspace.pathSlice(), path)) {
            return workspace;
        }
    }

    return null;
}

pub fn contains(reader: Reader, location: source_namespace.schema.TabLocation) bool {
    const workspace = reader.find(location.workspace) orelse return false;
    return workspace.containsTab(location.tab_id);
}

pub fn defaultTab(reader: Reader, location: source_namespace.schema.WorkspaceLocation) ?source_namespace.schema.TabId {
    const workspace = reader.find(location) orelse return null;
    return workspace.defaultTab();
}

pub fn workspacePath(reader: Reader, location: source_namespace.schema.WorkspaceLocation) ?[]const u8 {
    const workspace = reader.find(location) orelse return null;
    return workspace.pathSlice();
}

pub fn workspaceName(reader: Reader, location: source_namespace.schema.WorkspaceLocation) ?[]const u8 {
    const workspace = reader.find(location) orelse return null;
    return workspace.name();
}

/// The user-chosen workspace name, or null when the name derives from
/// the path.
///
/// ```zig
/// const explicit = reader.explicitName(location) orelse "";
/// ```
pub fn explicitName(reader: Reader, location: source_namespace.schema.WorkspaceLocation) ?[]const u8 {
    const workspace = reader.find(location) orelse return null;
    return workspace.explicitName();
}

pub fn tabLabel(reader: Reader, location: source_namespace.schema.TabLocation) ?[]const u8 {
    const workspace = reader.find(location.workspace) orelse return null;
    return workspace.tabLabel(location.tab_id);
}

/// Returns the preceding aggregate in list order, wrapping at the start.
///
/// ```zig
/// const previous = reader.previousWorkspace(workspace_id);
/// ```
pub fn previousWorkspace(reader: Reader, workspace_id: source_namespace.schema.WorkspaceId) ?source_namespace.schema.WorkspaceId {
    if (reader.state.count < 2) {
        return null;
    }

    var current_index: ?usize = null;

    for (&reader.state.items, 0..) |*slot, index| {
        const workspace = if (slot.*) |*value| value else continue;

        if (workspace.id == workspace_id) {
            current_index = index;
            break;
        }
    }

    const current = current_index orelse return null;

    for (1..reader.state.items.len) |offset| {
        const index = (current + reader.state.items.len - offset) % reader.state.items.len;
        const workspace = if (reader.state.items[index]) |*value| value else continue;
        return workspace.id;
    }

    return null;
}

pub fn totalTabs(reader: Reader) usize {
    var count_value: usize = 0;

    for (&reader.state.items) |*slot| {
        const workspace = if (slot.*) |*value| value else continue;
        count_value += workspace.tabCount();
    }

    return count_value;
}

/// Writes the workspace snapshot projection into caller-owned tab storage.
/// Returned labels borrow aggregate storage until its next mutation.
///
/// ```zig
/// var tabs: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
/// const snapshot = reader.descriptors(location, &tabs) orelse return;
/// ```
pub fn descriptors(reader: Reader, location: source_namespace.schema.WorkspaceLocation, output: *[workspace_mod.max_tabs_per_workspace]source_namespace.schema.TabDescriptor) ?DescriptorSnapshot {
    const workspace = reader.find(location) orelse return null;

    return .{
        .name = workspace.name(),
        .tabs = workspace.writeDescriptors(output),
    };
}

/// Writes the stable workspace-list projection into caller-owned storage.
/// Returned slices borrow aggregate data and remain valid until mutation.
///
/// ```zig
/// var entries: [max_workspaces]schema.WorkspaceListEntry = undefined;
/// const list = reader.listEntries(&entries);
/// ```
pub fn listEntries(reader: Reader, output: *[state_mod.max_workspaces]source_namespace.schema.WorkspaceListEntry) []const source_namespace.schema.WorkspaceListEntry {
    var count_value: usize = 0;

    for (&reader.state.items) |*slot| {
        const workspace = if (slot.*) |*value| value else continue;
        output[count_value] = .{
            .workspace = workspace.id,
            .name = workspace.name(),
            .path = workspace.pathSlice(),
            .tab_count = @intCast(workspace.tabCount()),
            .branch = workspace.gitBranch(),
            .dirty = workspace.git_dirty,
        };
        count_value += 1;
    }

    return output[0..count_value];
}
