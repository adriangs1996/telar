//! Workspaces and their tabs, as the runtime owns them.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("pane.zig");

const schema = core.schema;
const PaneStore = pane_mod.PaneStore;

pub const max_workspaces = 64;

pub const max_tabs_per_workspace = schema.max_tabs_per_workspace;

pub const Tab = struct {
    id: schema.TabId,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    label_len: u8 = 0,

    pub fn init(id: schema.TabId, label: []const u8) Tab {
        var tab: Tab = .{ .id = id };
        tab.setLabel(label);
        return tab;
    }

    pub fn setLabel(tab: *Tab, label: []const u8) void {
        std.debug.assert(label.len != 0 and label.len <= tab.label.len);
        @memcpy(tab.label[0..label.len], label);
        tab.label_len = @intCast(label.len);
    }

    pub fn labelSlice(tab: *const Tab) []const u8 {
        return tab.label[0..tab.label_len];
    }
};

pub const Workspace = struct {
    id: schema.WorkspaceId,
    path: []u8,
    explicit_name: [schema.max_tab_label_bytes]u8 = undefined,
    explicit_name_len: u8 = 0,
    tabs: [max_tabs_per_workspace]?Tab = [_]?Tab{null} ** max_tabs_per_workspace,
    tab_count: usize = 0,

    pub fn name(workspace: *const Workspace) []const u8 {
        if (workspace.explicit_name_len != 0)
            return workspace.explicit_name[0..workspace.explicit_name_len];
        return std.fs.path.basename(workspace.path);
    }

    fn setExplicitName(workspace: *Workspace, name_value: []const u8) void {
        std.debug.assert(name_value.len != 0 and name_value.len <= workspace.explicit_name.len);
        @memcpy(workspace.explicit_name[0..name_value.len], name_value);
        workspace.explicit_name_len = @intCast(name_value.len);
    }

    pub fn defaultTab(workspace: *const Workspace) schema.TabId {
        std.debug.assert(workspace.tab_count != 0);
        return workspace.tabs[0].?.id;
    }

    pub fn containsTab(workspace: *const Workspace, tab_id: schema.TabId) bool {
        for (workspace.tabs) |candidate|
            if (candidate != null and candidate.?.id == tab_id) return true;
        return false;
    }

    pub fn findTab(workspace: *Workspace, tab_id: schema.TabId) ?*Tab {
        for (&workspace.tabs) |*slot| {
            const tab = if (slot.*) |*value| value else continue;
            if (tab.id == tab_id) return tab;
        }
        return null;
    }

    pub fn tabIndex(workspace: *const Workspace, tab_id: schema.TabId) ?usize {
        for (workspace.tabs[0..workspace.tab_count], 0..) |slot, index|
            if (slot != null and slot.?.id == tab_id) return index;
        return null;
    }

    pub fn appendTab(workspace: *Workspace, tab: Tab) !u16 {
        if (workspace.tab_count == workspace.tabs.len) return error.TabLimitReached;
        const index = workspace.tab_count;
        workspace.tabs[index] = tab;
        workspace.tab_count += 1;
        return @intCast(index);
    }

    pub fn removeTab(workspace: *Workspace, tab_id: schema.TabId) bool {
        const index = workspace.tabIndex(tab_id) orelse return false;
        var cursor = index;
        while (cursor + 1 < workspace.tab_count) : (cursor += 1)
            workspace.tabs[cursor] = workspace.tabs[cursor + 1];
        workspace.tab_count -= 1;
        workspace.tabs[workspace.tab_count] = null;
        return true;
    }

    pub fn moveTab(
        workspace: *Workspace,
        tab_id: schema.TabId,
        direction: schema.TabMoveDirection,
    ) ?u16 {
        const index = workspace.tabIndex(tab_id) orelse return null;
        const target = switch (direction) {
            .previous => if (index == 0) index else index - 1,
            .next => if (index + 1 == workspace.tab_count) index else index + 1,
        };
        if (target != index) std.mem.swap(?Tab, &workspace.tabs[index], &workspace.tabs[target]);
        return @intCast(target);
    }
};

pub const WorkspaceStore = struct {
    pub const Ensured = struct {
        location: schema.TabLocation,
        created: bool,
    };

    pub const DescriptorSnapshot = struct {
        name: []const u8,
        tabs: []const schema.TabDescriptor,
    };

    gpa: std.mem.Allocator,
    items: [max_workspaces]?Workspace = [_]?Workspace{null} ** max_workspaces,
    count: usize = 0,
    next_id: u64 = 1,
    next_tab_id: u64 = 1,
    /// Covers what `workspace_list` shows: the set of workspaces, their names,
    /// paths, and tab counts. Tab labels are not on the list, so tab renames do
    /// not bump it. Starts at 1 and never returns to 0, like the agent store.
    revision: u64 = 1,

    pub fn init(gpa: std.mem.Allocator) WorkspaceStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *WorkspaceStore) void {
        for (&store.items) |*slot| {
            if (slot.*) |workspace| store.gpa.free(workspace.path);
            slot.* = null;
        }
    }

    pub fn ensure(store: *WorkspaceStore, path: []const u8) !Ensured {
        for (&store.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            if (std.mem.eql(u8, workspace.path, path))
                return .{
                    .location = .{
                        .workspace = .{ .workspace = workspace.id },
                        .tab_id = workspace.defaultTab(),
                    },
                    .created = false,
                };
        }
        return .{ .location = try store.insert(path, null), .created = true };
    }

    /// Creates a distinct workspace even when another workspace uses the same
    /// launch path. Interactive `new_workspace` depends on identity, not path
    /// uniqueness; `ensure` remains the attach-or-create operation.
    pub fn create(
        store: *WorkspaceStore,
        path: []const u8,
        name_value: []const u8,
    ) !schema.TabLocation {
        if (name_value.len == 0 or name_value.len > schema.max_tab_label_bytes)
            return error.InvalidWorkspaceName;
        return store.insert(path, name_value);
    }

    pub fn rename(
        store: *WorkspaceStore,
        location: schema.WorkspaceLocation,
        name_value: []const u8,
    ) !void {
        if (name_value.len == 0 or name_value.len > schema.max_tab_label_bytes)
            return error.InvalidWorkspaceName;
        const workspace = store.find(location) orelse return error.WorkspaceNotFound;
        workspace.setExplicitName(name_value);
        store.bumpRevision();
    }

    fn insert(
        store: *WorkspaceStore,
        path: []const u8,
        explicit_name: ?[]const u8,
    ) !schema.TabLocation {
        if (store.count == max_workspaces) return error.WorkspaceLimitReached;
        const path_copy = try store.gpa.dupe(u8, path);
        errdefer store.gpa.free(path_copy);
        const workspace_id = try schema.id.workspace(store.next_id);
        store.next_id += 1;
        const tab_id = try schema.id.tab(store.next_tab_id);
        store.next_tab_id += 1;
        for (&store.items) |*slot| {
            if (slot.* == null) {
                var workspace: Workspace = .{ .id = workspace_id, .path = path_copy };
                if (explicit_name) |name_value| workspace.setExplicitName(name_value);
                _ = try workspace.appendTab(.init(tab_id, "main"));
                slot.* = workspace;
                store.count += 1;
                store.bumpRevision();
                return .{
                    .workspace = .{ .workspace = workspace_id },
                    .tab_id = tab_id,
                };
            }
        }
        unreachable;
    }

    pub fn contains(store: *const WorkspaceStore, location: schema.TabLocation) bool {
        const workspace_id = switch (location.workspace) {
            .workspace => |id| id,
            .worktree => return false,
        };
        for (&store.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            if (workspace.id == workspace_id)
                return workspace.containsTab(location.tab_id);
        }
        return false;
    }

    pub fn find(store: *WorkspaceStore, location: schema.WorkspaceLocation) ?*Workspace {
        const workspace_id = switch (location) {
            .workspace => |id| id,
            .worktree => return null,
        };
        for (&store.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            if (workspace.id == workspace_id) return workspace;
        }
        return null;
    }

    pub fn findTab(store: *WorkspaceStore, location: schema.TabLocation) ?*Tab {
        const workspace = store.find(location.workspace) orelse return null;
        return workspace.findTab(location.tab_id);
    }

    pub fn createTab(
        store: *WorkspaceStore,
        workspace_location: schema.WorkspaceLocation,
        requested_label: []const u8,
        label_buffer: *[schema.max_tab_label_bytes]u8,
    ) !struct { location: schema.TabLocation, position: u16 } {
        const workspace = store.find(workspace_location) orelse return error.WorkspaceNotFound;
        const tab_id = try schema.id.tab(store.next_tab_id);
        var generated: []const u8 = requested_label;
        if (generated.len == 0) {
            generated = try std.fmt.bufPrint(label_buffer, "tab {d}", .{schema.id.raw(tab_id)});
        }
        const position = try workspace.appendTab(.init(tab_id, generated));
        store.next_tab_id += 1;
        store.bumpRevision();
        return .{
            .location = .{ .workspace = workspace_location, .tab_id = tab_id },
            .position = position,
        };
    }

    pub const TabRemoval = struct {
        workspace_closed: bool,
        previous_workspace: ?schema.WorkspaceId = null,
    };

    pub fn removeTab(store: *WorkspaceStore, location: schema.TabLocation) ?TabRemoval {
        const workspace = store.find(location.workspace) orelse return null;
        if (!workspace.removeTab(location.tab_id)) return null;
        store.bumpRevision();
        const workspace_closed = workspace.tab_count == 0;
        var previous_workspace: ?schema.WorkspaceId = null;
        if (workspace_closed) {
            const workspace_id = switch (location.workspace) {
                .workspace => |id| id,
                .worktree => unreachable,
            };
            previous_workspace = store.previousWorkspace(workspace_id);
            store.remove(workspace_id);
        }
        return .{
            .workspace_closed = workspace_closed,
            .previous_workspace = previous_workspace,
        };
    }

    /// Returns the preceding workspace in the same stable order exposed by
    /// `listEntries`, wrapping from the first slot to the last.
    pub fn previousWorkspace(
        store: *const WorkspaceStore,
        workspace_id: schema.WorkspaceId,
    ) ?schema.WorkspaceId {
        if (store.count < 2) return null;
        var current_index: ?usize = null;
        for (store.items, 0..) |slot, index| {
            const workspace = slot orelse continue;
            if (workspace.id == workspace_id) {
                current_index = index;
                break;
            }
        }
        const current = current_index orelse return null;
        for (1..store.items.len) |offset| {
            const index = (current + store.items.len - offset) % store.items.len;
            const workspace = store.items[index] orelse continue;
            return workspace.id;
        }
        return null;
    }

    pub fn totalTabs(store: *const WorkspaceStore) usize {
        var count: usize = 0;
        for (store.items) |slot| {
            const workspace = slot orelse continue;
            count += workspace.tab_count;
        }
        return count;
    }

    pub fn descriptors(
        store: *WorkspaceStore,
        workspace_location: schema.WorkspaceLocation,
        panes: *const PaneStore,
        output: *[max_tabs_per_workspace]schema.TabDescriptor,
    ) ?DescriptorSnapshot {
        const workspace = store.find(workspace_location) orelse return null;
        for (workspace.tabs[0..workspace.tab_count], 0..) |*slot, index| {
            const tab = &slot.*.?;
            const location: schema.TabLocation = .{
                .workspace = workspace_location,
                .tab_id = tab.id,
            };
            output[index] = .{
                .tab_id = tab.id,
                .position = @intCast(index),
                .pane_count = panes.countAt(location),
                .label = tab.labelSlice(),
            };
        }
        return .{
            .name = workspace.name(),
            .tabs = output[0..workspace.tab_count],
        };
    }

    pub fn remove(store: *WorkspaceStore, workspace_id: schema.WorkspaceId) void {
        for (&store.items) |*slot| {
            const workspace = slot.* orelse continue;
            if (workspace.id == workspace_id) {
                store.gpa.free(workspace.path);
                slot.* = null;
                store.count -= 1;
                store.bumpRevision();
                return;
            }
        }
        unreachable;
    }

    /// Entries for the `workspace_list` message, in stable slot order. The
    /// slices borrow the store; encode before the next mutation.
    pub fn listEntries(
        store: *const WorkspaceStore,
        output: *[max_workspaces]schema.WorkspaceListEntry,
    ) []const schema.WorkspaceListEntry {
        var count: usize = 0;
        for (&store.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            output[count] = .{
                .workspace = workspace.id,
                .name = workspace.name(),
                .path = workspace.path,
                .tab_count = @intCast(workspace.tab_count),
            };
            count += 1;
        }
        return output[0..count];
    }

    fn bumpRevision(store: *WorkspaceStore) void {
        store.revision +%= 1;
        if (store.revision == 0) store.revision = 1;
    }
};

test "the list revision tracks workspace names, membership and tab counts" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();
    const initial = store.revision;

    const ensured = try store.ensure("/work/project");
    try std.testing.expect(store.revision != initial);
    const after_ensure = store.revision;

    var label_buffer: [schema.max_tab_label_bytes]u8 = undefined;
    const logs = try store.createTab(ensured.location.workspace, "logs", &label_buffer);
    try std.testing.expect(store.revision != after_ensure);
    const after_create = store.revision;

    store.findTab(logs.location).?.setLabel("server");
    try std.testing.expectEqual(after_create, store.revision);

    try store.rename(ensured.location.workspace, "agents");
    try std.testing.expect(store.revision != after_create);
    const after_rename = store.revision;

    var output: [max_workspaces]schema.WorkspaceListEntry = undefined;
    const entries = store.listEntries(&output);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("agents", entries[0].name);
    try std.testing.expectEqualStrings("/work/project", entries[0].path);
    try std.testing.expectEqual(@as(u16, 2), entries[0].tab_count);

    _ = store.removeTab(logs.location).?;
    try std.testing.expect(store.revision != after_rename);
}

test "workspace and default tab identities are stable per path" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    const first = try store.ensure("/work/project");
    const same = try store.ensure("/work/project");
    const other = try store.ensure("/work/other");

    try std.testing.expect(first.created);
    try std.testing.expect(!same.created);
    try std.testing.expect(other.created);
    try std.testing.expectEqualDeep(first.location, same.location);
    try std.testing.expect(!std.meta.eql(first.location, other.location));
    try std.testing.expect(store.contains(first.location));
    var unknown_tab = first.location;
    unknown_tab.tab_id = try schema.id.tab(999);
    try std.testing.expect(!store.contains(unknown_tab));
    try std.testing.expectEqual(@as(usize, 2), store.count);
}

test "explicit creation permits distinct workspaces with the same path" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    const first = try store.create("/work/project", "frontend");
    const second = try store.create("/work/project", "backend");
    try std.testing.expect(!std.meta.eql(first, second));
    try std.testing.expectEqual(@as(usize, 2), store.count);
    try std.testing.expectEqualStrings(
        store.find(first.workspace).?.path,
        store.find(second.workspace).?.path,
    );
    try std.testing.expectEqualStrings("frontend", store.find(first.workspace).?.name());
    try std.testing.expectEqualStrings("backend", store.find(second.workspace).?.name());
}

test "workspace name is the final path segment" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    const ensured = try store.ensure("/work/telar");
    const workspace = store.find(ensured.location.workspace).?;
    try std.testing.expectEqualStrings("telar", workspace.name());
}

test "workspace rename replaces the path-derived name" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    const ensured = try store.ensure("/work/telar");
    try store.rename(ensured.location.workspace, "agents");
    try std.testing.expectEqualStrings("agents", store.find(ensured.location.workspace).?.name());
}

test "an uncommitted workspace can be rolled back" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    const workspace = try store.ensure("/invalid/cwd");
    const workspace_id = switch (workspace.location.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    store.remove(workspace_id);

    try std.testing.expectEqual(@as(usize, 0), store.count);
}

test "workspace tabs create rename reorder and close" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();
    const ensured = try store.ensure("/work/project");
    var label_buffer: [schema.max_tab_label_bytes]u8 = undefined;
    const logs = try store.createTab(ensured.location.workspace, "logs", &label_buffer);
    const generated = try store.createTab(ensured.location.workspace, "", &label_buffer);

    try std.testing.expectEqual(@as(u16, 1), logs.position);
    try std.testing.expectEqual(@as(u16, 2), generated.position);
    try std.testing.expectEqualStrings("tab 3", store.findTab(generated.location).?.labelSlice());

    store.findTab(logs.location).?.setLabel("server");
    try std.testing.expectEqualStrings("server", store.findTab(logs.location).?.labelSlice());
    const workspace = store.find(ensured.location.workspace).?;
    try std.testing.expectEqual(@as(u16, 0), workspace.moveTab(logs.location.tab_id, .previous).?);
    try std.testing.expectEqual(logs.location.tab_id, workspace.defaultTab());

    var panes: PaneStore = .{};
    var descriptors: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
    const snapshot = store.descriptors(
        ensured.location.workspace,
        &panes,
        &descriptors,
    ).?;
    try std.testing.expectEqualStrings("project", snapshot.name);
    try std.testing.expectEqual(@as(usize, 3), snapshot.tabs.len);
    try std.testing.expectEqualStrings("server", snapshot.tabs[0].label);

    try std.testing.expect(!store.removeTab(logs.location).?.workspace_closed);
    try std.testing.expect(!store.removeTab(generated.location).?.workspace_closed);
    const removal = store.removeTab(ensured.location).?;
    try std.testing.expect(removal.workspace_closed);
    try std.testing.expect(removal.previous_workspace == null);
    try std.testing.expectEqual(@as(usize, 0), store.count);
}

test "closing a workspace selects its canonical predecessor" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    const first = try store.create("/work/first", "first");
    const second = try store.create("/work/second", "second");
    const third = try store.create("/work/third", "third");
    const first_id = switch (first.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    const third_id = switch (third.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };

    const middle = store.removeTab(.{
        .workspace = second.workspace,
        .tab_id = store.find(second.workspace).?.defaultTab(),
    }).?;
    try std.testing.expect(middle.workspace_closed);
    try std.testing.expectEqual(first_id, middle.previous_workspace.?);

    const wrapped = store.removeTab(.{
        .workspace = first.workspace,
        .tab_id = store.find(first.workspace).?.defaultTab(),
    }).?;
    try std.testing.expect(wrapped.workspace_closed);
    try std.testing.expectEqual(third_id, wrapped.previous_workspace.?);

    const last = store.removeTab(.{
        .workspace = third.workspace,
        .tab_id = store.find(third.workspace).?.defaultTab(),
    }).?;
    try std.testing.expect(last.workspace_closed);
    try std.testing.expect(last.previous_workspace == null);
}
