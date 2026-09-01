//! Workspace aggregate and its tab entities.

const std = @import("std");
const core = @import("telar-core");
const events = @import("events.zig");

const schema = core.schema;

pub const max_tabs_per_workspace = schema.max_tabs_per_workspace;

const Tab = struct {
    id: schema.TabId,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    label_len: u8 = 0,

    fn init(id: schema.TabId, label: []const u8) !Tab {
        var tab: Tab = .{ .id = id };
        try tab.rename(label);
        return tab;
    }

    fn rename(tab: *Tab, label: []const u8) !void {
        if (label.len == 0 or label.len > tab.label.len) {
            return error.InvalidTabLabel;
        }

        @memcpy(tab.label[0..label.len], label);
        tab.label_len = @intCast(label.len);
    }

    fn labelSlice(tab: *const Tab) []const u8 {
        return tab.label[0..tab.label_len];
    }
};

pub const Workspace = struct {
    pub const Init = struct {
        id: schema.WorkspaceId,
        path: []u8,
        default_tab_id: schema.TabId,
        explicit_name: ?[]const u8 = null,
    };

    id: schema.WorkspaceId,
    path: []u8,
    explicit_name: [schema.max_tab_label_bytes]u8 = undefined,
    explicit_name_len: u8 = 0,
    tabs: [max_tabs_per_workspace]?Tab = [_]?Tab{null} ** max_tabs_per_workspace,
    tab_count: usize = 0,
    git_branch: [schema.max_git_branch_bytes]u8 = undefined,
    git_branch_len: u8 = 0,
    git_dirty: bool = false,
    git_checked_at_ms: i64 = 0,
    git_probe_pending: bool = false,

    pub fn init(options: Init) !Workspace {
        if (options.path.len == 0 or options.path.len > schema.max_cwd_bytes or std.mem.indexOfScalar(u8, options.path, 0) != null) {
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
        if (workspace.explicit_name_len == 0) return null;
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

    pub fn defaultTab(workspace: *const Workspace) schema.TabId {
        std.debug.assert(workspace.tab_count != 0);
        return workspace.tabs[0].?.id;
    }

    pub fn tabCount(workspace: *const Workspace) usize {
        return workspace.tab_count;
    }

    pub fn containsTab(workspace: *const Workspace, tab_id: schema.TabId) bool {
        return workspace.findTabConst(tab_id) != null;
    }

    /// Adds one tab after validating its label and returns an owned event for
    /// the caller's transaction boundary. An empty requested label is replaced
    /// with the stable `tab <id>` default used by the runtime.
    ///
    /// ```zig
    /// const created = try workspace.createTab(tab_id, "logs");
    /// ```
    pub fn createTab(workspace: *Workspace, tab_id: schema.TabId, requested_label: []const u8) !events.TabCreated {
        if (workspace.tab_count == workspace.tabs.len) {
            return error.TabLimitReached;
        }

        var generated_label: [schema.max_tab_label_bytes]u8 = undefined;
        const label = if (requested_label.len == 0)
            try std.fmt.bufPrint(&generated_label, "tab {d}", .{schema.id.raw(tab_id)})
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
    pub fn renameTab(workspace: *Workspace, tab_id: schema.TabId, label: []const u8) !events.TabRenamed {
        const tab = workspace.findTab(tab_id) orelse return error.TabNotFound;
        try tab.rename(label);

        return events.TabRenamed.init(.{
            .workspace = .{ .workspace = workspace.id },
            .tab_id = tab.id,
        }, tab.labelSlice()) catch unreachable;
    }

    pub fn removeTab(workspace: *Workspace, tab_id: schema.TabId) bool {
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
    pub fn moveTab(workspace: *Workspace, tab_id: schema.TabId, direction: schema.TabMoveDirection) ?events.TabMoved {
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

    pub fn tabLabel(workspace: *const Workspace, tab_id: schema.TabId) ?[]const u8 {
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
    pub fn writeDescriptors(workspace: *const Workspace, output: *[max_tabs_per_workspace]schema.TabDescriptor) []schema.TabDescriptor {
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

    fn findTab(workspace: *Workspace, tab_id: schema.TabId) ?*Tab {
        for (&workspace.tabs) |*slot| {
            const tab = if (slot.*) |*value| value else continue;

            if (tab.id == tab_id) {
                return tab;
            }
        }

        return null;
    }

    fn findTabConst(workspace: *const Workspace, tab_id: schema.TabId) ?*const Tab {
        for (&workspace.tabs) |*slot| {
            const tab = if (slot.*) |*value| value else continue;

            if (tab.id == tab_id) {
                return tab;
            }
        }

        return null;
    }

    fn tabIndex(workspace: *const Workspace, tab_id: schema.TabId) ?usize {
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
};

fn testingWorkspace() !Workspace {
    const path = try std.testing.allocator.dupe(u8, "/work/telar");
    errdefer std.testing.allocator.free(path);

    return Workspace.init(.{
        .id = try schema.id.workspace(1),
        .path = path,
        .default_tab_id = try schema.id.tab(1),
    });
}

test "workspace derives its name from its path until explicitly renamed" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("telar", workspace.name());
    const renamed = try workspace.rename("agents");
    try std.testing.expectEqualStrings("agents", workspace.name());
    try std.testing.expectEqualStrings("agents", renamed.nameSlice());

    try std.testing.expectError(error.InvalidWorkspaceName, workspace.rename(""));
    try std.testing.expectEqualStrings("agents", workspace.name());
}

test "workspace uses its root path as a non-empty derived name" {
    const path = try std.testing.allocator.dupe(u8, "/");
    var workspace = try Workspace.init(.{
        .id = try schema.id.workspace(1),
        .path = path,
        .default_tab_id = try schema.id.tab(1),
    });
    defer workspace.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/", workspace.name());
}

test "workspace rejects paths that cannot cross the runtime protocol" {
    const workspace_id = try schema.id.workspace(1);
    const tab_id = try schema.id.tab(1);
    const invalid_paths = [_][]const u8{
        "",
        "bad\x00path",
    };

    for (invalid_paths) |invalid| {
        const path = try std.testing.allocator.dupe(u8, invalid);
        defer std.testing.allocator.free(path);

        try std.testing.expectError(error.InvalidWorkspacePath, Workspace.init(.{
            .id = workspace_id,
            .path = path,
            .default_tab_id = tab_id,
        }));
    }

    const oversized_source: [schema.max_cwd_bytes + 1]u8 = @splat('x');
    const oversized = try std.testing.allocator.dupe(u8, &oversized_source);
    defer std.testing.allocator.free(oversized);

    try std.testing.expectError(error.InvalidWorkspacePath, Workspace.init(.{
        .id = workspace_id,
        .path = oversized,
        .default_tab_id = tab_id,
    }));
}

test "workspace explicit names follow the request label limit" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);
    const accepted: [schema.max_tab_label_bytes]u8 = @splat('a');
    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');

    const renamed = try workspace.rename(&accepted);

    try std.testing.expectEqualSlices(u8, &accepted, workspace.name());
    try std.testing.expectEqualSlices(u8, &accepted, renamed.nameSlice());
    try std.testing.expectError(error.InvalidWorkspaceName, workspace.rename(&oversized));
    try std.testing.expectEqualSlices(u8, &accepted, workspace.name());
}

test "renameTab validates and mutates only the requested tab" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);
    const logs_id = try schema.id.tab(2);
    _ = try workspace.createTab(logs_id, "logs");

    const renamed = try workspace.renameTab(logs_id, "server");
    try std.testing.expectEqualStrings("server", workspace.tabLabel(logs_id).?);
    try std.testing.expectEqualStrings("main", workspace.tabLabel(try schema.id.tab(1)).?);
    try std.testing.expectEqualStrings("server", renamed.labelSlice());
    try std.testing.expectEqual(logs_id, renamed.location.tab_id);

    try std.testing.expectError(error.InvalidTabLabel, workspace.renameTab(logs_id, ""));
    try std.testing.expectEqualStrings("server", workspace.tabLabel(logs_id).?);

    var oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, workspace.renameTab(logs_id, &oversized));
    try std.testing.expectEqualStrings("server", workspace.tabLabel(logs_id).?);

    try std.testing.expectError(error.TabNotFound, workspace.renameTab(try schema.id.tab(999), "missing"));

    _ = try workspace.renameTab(logs_id, "api");
    try std.testing.expectEqualStrings("server", renamed.labelSlice());
}

test "tabs are created moved described and removed through the aggregate" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);
    const logs_id = try schema.id.tab(2);
    const generated_id = try schema.id.tab(3);

    const logs = try workspace.createTab(logs_id, "logs");
    const generated = try workspace.createTab(generated_id, "");
    try std.testing.expectEqual(@as(u16, 1), logs.position);
    try std.testing.expectEqual(@as(u16, 2), generated.position);
    try std.testing.expectEqual(logs_id, logs.location.tab_id);
    try std.testing.expectEqualStrings("logs", logs.labelSlice());
    try std.testing.expectEqualStrings("tab 3", generated.labelSlice());
    try std.testing.expectEqualStrings("tab 3", workspace.tabLabel(generated_id).?);

    const moved = workspace.moveTab(logs_id, .previous).?;
    try std.testing.expectEqual(@as(u16, 0), moved.position);
    try std.testing.expectEqual(logs_id, moved.location.tab_id);
    try std.testing.expectEqual(logs_id, workspace.defaultTab());

    var descriptors: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
    const snapshot = workspace.writeDescriptors(&descriptors);
    try std.testing.expectEqual(@as(usize, 3), snapshot.len);
    try std.testing.expectEqualStrings("logs", snapshot[0].label);

    try std.testing.expect(workspace.removeTab(logs_id));
    try std.testing.expect(!workspace.removeTab(logs_id));
    try std.testing.expectEqual(@as(usize, 2), workspace.tabCount());
}

test "workspace rejects tabs beyond its fixed capacity without mutation" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);

    for (2..max_tabs_per_workspace + 1) |raw_id| {
        _ = try workspace.createTab(try schema.id.tab(raw_id), "tab");
    }

    try std.testing.expectEqual(max_tabs_per_workspace, workspace.tabCount());
    try std.testing.expectError(
        error.TabLimitReached,
        workspace.createTab(try schema.id.tab(max_tabs_per_workspace + 1), "overflow"),
    );
    try std.testing.expectEqual(max_tabs_per_workspace, workspace.tabCount());
}
