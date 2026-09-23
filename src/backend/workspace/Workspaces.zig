const revisions = @import("../revisions.zig");
const core = @import("telar-core");
const std = @import("std");
const ClientKey = @import("../history/ClientKey.zig");
const TabRemoved = @import("TabRemoved.zig");
/// The runtime's workspaces as a table of columns: identity, path, name,
/// ordered tabs, Git state and the geometry lease, one row per workspace.
/// Rows keep their slot for life, so slot order is the workspace list order.
/// A proposed row holds identities and a lease while it stays invisible;
/// only `commit` publishes it.
const Workspaces = @This();

pub const capacity = 64;
const max_tabs = core.max_tabs_per_workspace;
const Rows = std.bit_set.IntegerBitSet(capacity);

comptime {
    std.debug.assert(max_tabs <= std.math.maxInt(u8));
}

id: [capacity]core.WorkspaceId = @splat(.invalid),
path: [capacity][]u8 = undefined,
explicit_name: [capacity][core.max_tab_label_bytes]u8 = undefined,
explicit_name_len: [capacity]u8 = @splat(0),
tab_count: [capacity]u8 = @splat(0),
tab_id: [capacity][max_tabs]core.TabId = undefined,
tab_label: [capacity][max_tabs][core.max_tab_label_bytes]u8 = undefined,
tab_label_len: [capacity][max_tabs]u8 = undefined,
git_branch: [capacity][core.max_git_branch_bytes]u8 = undefined,
git_branch_len: [capacity]u8 = @splat(0),
git_dirty: [capacity]bool = @splat(false),
git_checked_at_ms: [capacity]i64 = @splat(0),
/// The client generation that may resize this workspace's panes.
lease: [capacity]?ClientKey = @splat(null),
/// Rows that hold storage: proposed or committed.
reserved: Rows = .initEmpty(),
/// Committed rows, the only ones projections and lookups by client see.
visible: Rows = .initEmpty(),
count: usize = 0,
index: core.GenericSlotIndex(2 * capacity) = .{},
/// The one workspace whose Git probe is in flight; it survives removal.
git_probe: ?core.WorkspaceId = null,
next_workspace_id: u64 = 1,
next_tab_id: u64 = 1,
/// Workspace-list revision; zero stays reserved for "never sent".
revision: u64 = 1,
/// Advances when a tab label changes; the workspace list does not carry
/// tab labels, but the agent snapshot does.
label_revision: u64 = 1,

/// Reserves an invisible row with the next identities and a copy of
/// `path`. The identities are consumed only by `commit`.
///
/// ```zig
/// const slot = try workspaces.propose(gpa, "/work/telar", null);
/// errdefer workspaces.rollback(gpa, slot);
/// ```
pub fn propose(self: *Workspaces, gpa: std.mem.Allocator, path: []const u8, explicit_name: ?[]const u8) !usize {
    const workspace_id = try core.workspace(self.next_workspace_id);
    const tab_id = try core.tab(self.next_tab_id);
    return self.reserve(gpa, .{
        .id = workspace_id,
        .path = path,
        .explicit_name = explicit_name,
        .first_tab_id = tab_id,
        .first_tab_label = "",
    });
}

/// Publishes a proposed row and consumes its identities exactly once.
///
/// ```zig
/// const location = workspaces.commit(slot);
/// ```
pub fn commit(self: *Workspaces, slot: usize) core.TabLocation {
    std.debug.assert(self.reserved.isSet(slot) and !self.visible.isSet(slot));
    std.debug.assert(core.raw(self.id[slot]) == self.next_workspace_id);
    std.debug.assert(core.raw(self.tab_id[slot][0]) == self.next_tab_id);

    self.visible.set(slot);
    self.count += 1;
    self.next_workspace_id += 1;
    self.next_tab_id += 1;
    self.advanceRevision();
    return self.defaultLocation(slot);
}

/// Releases a proposed row. A committed row is left untouched, so this is
/// safe in a transaction defer.
///
/// ```zig
/// defer workspaces.rollback(gpa, slot);
/// ```
pub fn rollback(self: *Workspaces, gpa: std.mem.Allocator, slot: usize) void {
    if (!self.reserved.isSet(slot) or self.visible.isSet(slot)) {
        return;
    }

    self.release(gpa, slot);
}

/// Proposes and commits one workspace. Equal paths stay distinct rows.
///
/// ```zig
/// const location = try workspaces.insert(gpa, "/work/telar", "backend");
/// ```
pub fn insert(self: *Workspaces, gpa: std.mem.Allocator, path: []const u8, explicit_name: ?[]const u8) !core.TabLocation {
    const slot = try self.propose(gpa, path, explicit_name);
    return self.commit(slot);
}

/// Rebuilds one checkpointed workspace with its original identities and
/// advances the counters past them. A duplicate identity is corrupt.
///
/// ```zig
/// const location = try workspaces.restore(gpa, .{ .id = id, .path = "/work", .explicit_name = null, .first_tab_id = tab, .first_tab_label = "" });
/// ```
pub fn restore(self: *Workspaces, gpa: std.mem.Allocator, request: RowRequest) !core.TabLocation {
    if (request.id == .invalid or request.first_tab_id == .invalid) {
        return error.InvalidCheckpointIdentity;
    }

    if (self.index.get(core.raw(request.id)) != null) {
        return error.DuplicateWorkspaceIdentity;
    }

    const slot = try self.reserve(gpa, request);
    self.visible.set(slot);
    self.count += 1;
    self.next_workspace_id = @max(self.next_workspace_id, core.raw(request.id) + 1);
    self.next_tab_id = @max(self.next_tab_id, core.raw(request.first_tab_id) + 1);
    self.advanceRevision();
    return self.defaultLocation(slot);
}

/// Rebuilds one additional checkpointed tab.
///
/// ```zig
/// try workspaces.restoreTab(.{ .workspace = workspace, .tab_id = tab_id }, "logs");
/// ```
pub fn restoreTab(self: *Workspaces, location: core.TabLocation, label: []const u8) !void {
    const slot = self.slotOf(location.workspace) orelse return error.WorkspaceNotFound;
    if (self.tabIndex(slot, location.tab_id) != null) {
        return error.DuplicateTabIdentity;
    }

    _ = try self.addTab(slot, location.tab_id, label);
    self.next_tab_id = @max(self.next_tab_id, core.raw(location.tab_id) + 1);
    self.advanceRevision();
}

/// Removes one committed row and releases its path.
///
/// ```zig
/// _ = workspaces.remove(gpa, workspace_id);
/// ```
pub fn remove(self: *Workspaces, gpa: std.mem.Allocator, workspace_id: core.WorkspaceId) bool {
    const slot = self.slotOf(.{ .workspace = workspace_id }) orelse return false;
    self.release(gpa, slot);
    self.count -= 1;
    self.advanceRevision();
    return true;
}

/// Removes a tab, and its workspace when that was the last tab. A removed
/// workspace reports its stable list predecessor for client handoff.
///
/// ```zig
/// const removed = workspaces.removeTab(gpa, location) orelse return;
/// ```
pub fn removeTab(self: *Workspaces, gpa: std.mem.Allocator, location: core.TabLocation) ?TabRemoved {
    const slot = self.slotOf(location.workspace) orelse return null;
    const tab_index = self.tabIndex(slot, location.tab_id) orelse return null;

    var cursor = tab_index;
    while (cursor + 1 < self.tab_count[slot]) : (cursor += 1) {
        self.copyTab(slot, cursor + 1, cursor);
    }

    self.tab_count[slot] -= 1;
    self.advanceRevision();

    const workspace_removed = self.tab_count[slot] == 0;
    var previous_workspace: ?core.WorkspaceId = null;
    if (workspace_removed) {
        previous_workspace = self.previousWorkspace(self.id[slot]);
        const removed = self.remove(gpa, self.id[slot]);
        std.debug.assert(removed);
    }

    return TabRemoved.init(location, workspace_removed, previous_workspace) catch unreachable;
}

/// Appends one tab. An empty label keeps the tab automatic: each client
/// derives its displayed name from its foreground application.
///
/// ```zig
/// const position = try workspaces.addTab(slot, tab_id, "logs");
/// ```
pub fn addTab(self: *Workspaces, slot: usize, tab_id: core.TabId, label: []const u8) !u16 {
    if (self.tab_count[slot] == max_tabs) {
        return error.TabLimitReached;
    }

    if (label.len > core.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    const position = self.tab_count[slot];
    self.tab_id[slot][position] = tab_id;
    self.setLabel(slot, position, label);
    self.tab_count[slot] += 1;
    return position;
}

/// Reorders a tab and returns its committed position. Moving beyond either
/// edge succeeds at that edge.
///
/// ```zig
/// const position = try workspaces.moveTab(location, .{ .direction = .previous });
/// ```
pub fn moveTab(self: *Workspaces, location: core.TabLocation, destination: core.TabMoveTarget) !u16 {
    const slot = self.slotOf(location.workspace) orelse return error.WorkspaceNotFound;
    const index = self.tabIndex(slot, location.tab_id) orelse return error.TabNotFound;
    const last = self.tab_count[slot] - 1;
    const target = if (destination.relative_to) |anchor| target: {
        const anchor_index = self.tabIndex(slot, anchor) orelse return error.TabNotFound;
        break :target destination.positionRelativeTo(index, anchor_index);
    } else switch (destination.direction) {
        .previous => index -| 1,
        .next => @min(index + 1, last),
    };

    const moved_id = self.tab_id[slot][index];
    const moved_label = self.tab_label[slot][index];
    const moved_len = self.tab_label_len[slot][index];
    var cursor = index;
    while (cursor < target) : (cursor += 1) {
        self.copyTab(slot, cursor + 1, cursor);
    }
    while (cursor > target) : (cursor -= 1) {
        self.copyTab(slot, cursor - 1, cursor);
    }

    self.tab_id[slot][target] = moved_id;
    self.tab_label[slot][target] = moved_label;
    self.tab_label_len[slot][target] = moved_len;
    return @intCast(target);
}

/// Returns the next tab identity without consuming it.
/// Example: `const tab_id = try workspaces.nextTabId();`.
pub fn nextTabId(self: *const Workspaces) !core.TabId {
    return core.tab(self.next_tab_id);
}

/// Consumes a tab identity once its tab's launch committed.
/// Example: `workspaces.recordTabCreated(tab_id);`.
pub fn recordTabCreated(self: *Workspaces, tab_id: core.TabId) void {
    std.debug.assert(core.raw(tab_id) == self.next_tab_id);
    self.next_tab_id += 1;
    self.advanceRevision();
}

/// Advances the list revision, keeping zero as the "never sent" sentinel.
/// Example: `workspaces.advanceRevision();`.
pub fn advanceRevision(self: *Workspaces) void {
    revisions.advance(&self.revision);
}

/// Validates and stores a non-empty tab label.
/// Example: `try workspaces.renameTab(location, "server");`.
pub fn renameTab(self: *Workspaces, location: core.TabLocation, label: []const u8) !void {
    const slot = self.slotOf(location.workspace) orelse return error.TabNotFound;
    const index = self.tabIndex(slot, location.tab_id) orelse return error.TabNotFound;

    if (label.len == 0 or label.len > core.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    self.setLabel(slot, index, label);
    revisions.advance(&self.label_revision);
}

/// Validates and stores a workspace's explicit name, then advances the
/// list revision.
/// Example: `try workspaces.rename(location, "backend");`.
pub fn rename(self: *Workspaces, location: core.WorkspaceLocation, name_value: []const u8) !void {
    const slot = self.slotOf(location) orelse return error.WorkspaceNotFound;
    try self.setExplicitName(slot, name_value);
    self.advanceRevision();
}

/// Releases every row's path.
/// Example: `workspaces.deinit(gpa);`.
pub fn deinit(self: *Workspaces, gpa: std.mem.Allocator) void {
    var rows = self.reserved.iterator(.{});
    while (rows.next()) |slot| {
        gpa.free(self.path[slot]);
    }

    self.* = .{};
}

/// Finds a committed row.
/// Example: `const slot = workspaces.slotOf(location) orelse return error.WorkspaceNotFound;`.
pub fn slotOf(self: *const Workspaces, location: core.WorkspaceLocation) ?usize {
    const slot = self.reservedSlotOf(location) orelse return null;
    return if (self.visible.isSet(slot)) slot else null;
}

/// Finds a committed or proposed row.
/// Example: `const slot = workspaces.reservedSlotOf(location) orelse return false;`.
pub fn reservedSlotOf(self: *const Workspaces, location: core.WorkspaceLocation) ?usize {
    const workspace_id = switch (location) {
        .workspace => |id| id,
        .worktree => return null,
    };

    return self.index.get(core.raw(workspace_id));
}

/// Finds a tab's position inside one row.
/// Example: `const index = workspaces.tabIndex(slot, tab_id) orelse return error.TabNotFound;`.
pub fn tabIndex(self: *const Workspaces, slot: usize, tab_id: core.TabId) ?usize {
    for (self.tab_id[slot][0..self.tab_count[slot]], 0..) |candidate, index| {
        if (candidate == tab_id) {
            return index;
        }
    }

    return null;
}

/// The explicit name, or the path's base name.
/// Example: `const label = workspaces.name(slot);`.
pub fn name(self: *const Workspaces, slot: usize) []const u8 {
    if (self.explicit_name_len[slot] != 0) {
        return self.explicit_name[slot][0..self.explicit_name_len[slot]];
    }

    const basename = std.fs.path.basename(self.path[slot]);
    return if (basename.len == 0) self.path[slot] else basename;
}

/// Example: `const label = workspaces.labelAt(slot, index);`.
pub fn labelAt(self: *const Workspaces, slot: usize, index: usize) []const u8 {
    return self.tab_label[slot][index][0..self.tab_label_len[slot][index]];
}

/// Example: `const branch = workspaces.gitBranch(slot);`.
pub fn gitBranch(self: *const Workspaces, slot: usize) []const u8 {
    return self.git_branch[slot][0..self.git_branch_len[slot]];
}

pub fn containsWorkspace(self: *const Workspaces, location: core.WorkspaceLocation) bool {
    return self.slotOf(location) != null;
}

pub fn contains(self: *const Workspaces, location: core.TabLocation) bool {
    const slot = self.slotOf(location.workspace) orelse return false;
    return self.tabIndex(slot, location.tab_id) != null;
}

pub fn defaultTab(self: *const Workspaces, location: core.WorkspaceLocation) ?core.TabId {
    const slot = self.slotOf(location) orelse return null;
    return self.tab_id[slot][0];
}

pub fn workspacePath(self: *const Workspaces, location: core.WorkspaceLocation) ?[]const u8 {
    const slot = self.slotOf(location) orelse return null;
    return self.path[slot];
}

pub fn workspaceName(self: *const Workspaces, location: core.WorkspaceLocation) ?[]const u8 {
    const slot = self.slotOf(location) orelse return null;
    return self.name(slot);
}

/// The user-chosen name, or null when the name derives from the path.
/// Example: `const explicit = workspaces.explicitName(location) orelse "";`.
pub fn explicitName(self: *const Workspaces, location: core.WorkspaceLocation) ?[]const u8 {
    const slot = self.slotOf(location) orelse return null;
    if (self.explicit_name_len[slot] == 0) {
        return null;
    }

    return self.explicit_name[slot][0..self.explicit_name_len[slot]];
}

pub fn tabLabel(self: *const Workspaces, location: core.TabLocation) ?[]const u8 {
    const slot = self.slotOf(location.workspace) orelse return null;
    const index = self.tabIndex(slot, location.tab_id) orelse return null;
    return self.labelAt(slot, index);
}

/// The default tab of the first committed workspace with `path`.
/// Example: `const location = workspaces.locationByPath("/work/telar") orelse return;`.
pub fn locationByPath(self: *const Workspaces, path: []const u8) ?core.TabLocation {
    var rows = self.visible.iterator(.{});
    while (rows.next()) |slot| {
        if (std.mem.eql(u8, self.path[slot], path)) {
            return self.defaultLocation(slot);
        }
    }

    return null;
}

/// The preceding committed workspace in list order, wrapping at the start.
/// Example: `const previous = workspaces.previousWorkspace(workspace_id);`.
pub fn previousWorkspace(self: *const Workspaces, workspace_id: core.WorkspaceId) ?core.WorkspaceId {
    if (self.count < 2) {
        return null;
    }

    const current = self.slotOf(.{ .workspace = workspace_id }) orelse return null;
    for (1..capacity) |offset| {
        const slot = (current + capacity - offset) % capacity;
        if (self.visible.isSet(slot)) {
            return self.id[slot];
        }
    }

    return null;
}

pub fn totalTabs(self: *const Workspaces) usize {
    var total: usize = 0;
    var rows = self.visible.iterator(.{});
    while (rows.next()) |slot| {
        total += self.tab_count[slot];
    }

    return total;
}

/// Writes one workspace's name and ordered tabs into caller storage. Labels
/// borrow the table until its next mutation.
///
/// ```zig
/// var tabs: [core.max_tabs_per_workspace]core.TabDescriptor = undefined;
/// const snapshot = workspaces.descriptors(location, &tabs) orelse return;
/// ```
pub fn descriptors(self: *const Workspaces, location: core.WorkspaceLocation, output: *[max_tabs]core.TabDescriptor) ?Descriptors {
    const slot = self.slotOf(location) orelse return null;
    for (0..self.tab_count[slot]) |index| {
        output[index] = .{
            .tab_id = self.tab_id[slot][index],
            .position = @intCast(index),
            .pane_count = 0,
            .label = self.labelAt(slot, index),
        };
    }

    return .{ .name = self.name(slot), .tabs = output[0..self.tab_count[slot]] };
}

/// Writes the workspace list in list order. Slices borrow the table.
///
/// ```zig
/// var entries: [Workspaces.capacity]core.WorkspaceListEntry = undefined;
/// const list = workspaces.listEntries(&entries);
/// ```
pub fn listEntries(self: *const Workspaces, output: *[capacity]core.WorkspaceListEntry) []const core.WorkspaceListEntry {
    var len: usize = 0;
    var rows = self.visible.iterator(.{});
    while (rows.next()) |slot| {
        output[len] = .{
            .workspace = self.id[slot],
            .name = self.name(slot),
            .path = self.path[slot],
            .tab_count = self.tab_count[slot],
            .branch = self.gitBranch(slot),
            .dirty = self.git_dirty[slot],
        };
        len += 1;
    }

    return output[0..len];
}

const Descriptors = struct {
    name: []const u8,
    tabs: []core.TabDescriptor,
};

const RowRequest = struct {
    id: core.WorkspaceId,
    path: []const u8,
    explicit_name: ?[]const u8,
    first_tab_id: core.TabId,
    first_tab_label: []const u8,
};

fn reserve(self: *Workspaces, gpa: std.mem.Allocator, request: RowRequest) !usize {
    if (request.path.len == 0 or request.path.len > core.max_cwd_bytes or std.mem.indexOfScalar(u8, request.path, 0) != null) {
        return error.InvalidWorkspacePath;
    }

    var free = self.reserved.complement().iterator(.{});
    const slot = free.next() orelse return error.WorkspaceLimitReached;
    std.debug.assert(self.index.get(core.raw(request.id)) == null);

    self.explicit_name_len[slot] = 0;
    if (request.explicit_name) |explicit| {
        try self.setExplicitName(slot, explicit);
    }

    if (request.first_tab_label.len > core.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    self.path[slot] = try gpa.dupe(u8, request.path);
    self.id[slot] = request.id;
    self.tab_id[slot][0] = request.first_tab_id;
    self.setLabel(slot, 0, request.first_tab_label);
    self.tab_count[slot] = 1;
    self.git_branch_len[slot] = 0;
    self.git_dirty[slot] = false;
    self.git_checked_at_ms[slot] = 0;
    self.lease[slot] = null;
    self.reserved.set(slot);
    self.index.put(core.raw(request.id), slot);
    return slot;
}

fn release(self: *Workspaces, gpa: std.mem.Allocator, slot: usize) void {
    gpa.free(self.path[slot]);
    self.index.remove(core.raw(self.id[slot]));
    self.id[slot] = .invalid;
    self.tab_count[slot] = 0;
    self.lease[slot] = null;
    self.reserved.unset(slot);
    self.visible.unset(slot);
}

fn setExplicitName(self: *Workspaces, slot: usize, value: []const u8) !void {
    if (value.len == 0 or value.len > core.max_tab_label_bytes) {
        return error.InvalidWorkspaceName;
    }

    @memcpy(self.explicit_name[slot][0..value.len], value);
    self.explicit_name_len[slot] = @intCast(value.len);
}

fn setLabel(self: *Workspaces, slot: usize, index: usize, value: []const u8) void {
    @memcpy(self.tab_label[slot][index][0..value.len], value);
    self.tab_label_len[slot][index] = @intCast(value.len);
}

fn copyTab(self: *Workspaces, slot: usize, from: usize, to: usize) void {
    self.tab_id[slot][to] = self.tab_id[slot][from];
    self.tab_label[slot][to] = self.tab_label[slot][from];
    self.tab_label_len[slot][to] = self.tab_label_len[slot][from];
}

fn defaultLocation(self: *const Workspaces, slot: usize) core.TabLocation {
    return .{ .workspace = .{ .workspace = self.id[slot] }, .tab_id = self.tab_id[slot][0] };
}

fn testingTable() !*Workspaces {
    const table = try std.testing.allocator.create(Workspaces);
    table.* = .{};
    return table;
}

fn destroyTestingTable(table: *Workspaces) void {
    table.deinit(std.testing.allocator);
    std.testing.allocator.destroy(table);
}

fn workspaceIdOf(location: core.TabLocation) core.WorkspaceId {
    return location.workspace.workspace;
}

test "the table starts empty with nonzero identities and revision, which never wraps to zero" {
    const table = try testingTable();
    defer destroyTestingTable(table);

    try std.testing.expectEqual(@as(usize, 0), table.count);
    try std.testing.expectEqual(@as(u64, 1), table.next_workspace_id);
    try std.testing.expectEqual(@as(u64, 1), table.next_tab_id);
    try std.testing.expectEqual(@as(u64, 1), table.revision);

    table.revision = std.math.maxInt(u64);
    table.advanceRevision();
    try std.testing.expectEqual(@as(u64, 1), table.revision);
}

test "paths identify workspaces and unknown tabs stay absent" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);

    const first = try table.insert(gpa, "/work/project", null);
    const other = try table.insert(gpa, "/work/other", null);

    try std.testing.expect(!std.meta.eql(first, other));
    try std.testing.expect(table.contains(first));
    try std.testing.expectEqualDeep(first, table.locationByPath("/work/project").?);
    try std.testing.expect(table.locationByPath("/work/missing") == null);

    var unknown_tab = first;
    unknown_tab.tab_id = try core.tab(999);
    try std.testing.expect(!table.contains(unknown_tab));
    try std.testing.expectEqual(@as(usize, 2), table.count);
}

test "checkpoint restoration keeps identities, automatic labels and explicit former defaults" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);

    const initial = try table.restore(gpa, .{ .id = @enumFromInt(1), .path = "/work/telar", .explicit_name = null, .first_tab_id = @enumFromInt(1), .first_tab_label = "" });
    const automatic: core.TabLocation = .{ .workspace = initial.workspace, .tab_id = @enumFromInt(2) };
    const explicit: core.TabLocation = .{ .workspace = initial.workspace, .tab_id = @enumFromInt(3) };
    try table.restoreTab(automatic, "");
    try table.restoreTab(explicit, "tab 3");
    const legacy = try table.restore(gpa, .{ .id = @enumFromInt(2), .path = "/work/legacy", .explicit_name = null, .first_tab_id = @enumFromInt(4), .first_tab_label = "main" });

    try std.testing.expectEqualStrings("", table.tabLabel(initial).?);
    try std.testing.expectEqualStrings("", table.tabLabel(automatic).?);
    try std.testing.expectEqualStrings("tab 3", table.tabLabel(explicit).?);
    try std.testing.expectEqualStrings("main", table.tabLabel(legacy).?);
}

test "restored workspaces advance the counters and reject duplicate identities" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);

    const location = try table.restore(gpa, .{ .id = @enumFromInt(4), .path = "/work/telar", .explicit_name = "core", .first_tab_id = @enumFromInt(9), .first_tab_label = "editor" });
    try table.restoreTab(.{ .workspace = location.workspace, .tab_id = @enumFromInt(11) }, "logs");

    try std.testing.expectEqual(@as(u64, 4), core.raw(workspaceIdOf(location)));
    try std.testing.expectEqualStrings("core", table.workspaceName(location.workspace).?);
    try std.testing.expectEqualStrings("editor", table.tabLabel(location).?);
    try std.testing.expectEqualStrings("logs", table.tabLabel(.{ .workspace = location.workspace, .tab_id = @enumFromInt(11) }).?);
    try std.testing.expectEqual(@as(u64, 5), table.next_workspace_id);
    try std.testing.expectEqual(@as(u64, 12), table.next_tab_id);
    try std.testing.expectError(error.DuplicateWorkspaceIdentity, table.restore(gpa, .{ .id = @enumFromInt(4), .path = "/elsewhere", .explicit_name = null, .first_tab_id = @enumFromInt(20), .first_tab_label = "main" }));

    const fresh = try table.insert(gpa, "/work/other", null);
    try std.testing.expectEqual(@as(u64, 5), core.raw(workspaceIdOf(fresh)));
    try std.testing.expectEqual(@as(u64, 12), core.raw(fresh.tab_id));
}

test "proposals stay invisible and preserve identities on rollback" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const initial_revision = table.revision;

    const slot = try table.propose(gpa, "/work/project", "backend");
    const proposed: core.TabLocation = .{ .workspace = .{ .workspace = table.id[slot] }, .tab_id = table.tab_id[slot][0] };

    try std.testing.expectEqual(@as(usize, 0), table.count);
    try std.testing.expect(!table.contains(proposed));
    try std.testing.expect(table.locationByPath("/work/project") == null);
    try std.testing.expectEqual(initial_revision, table.revision);
    try std.testing.expectEqualStrings("/work/project", table.path[slot]);
    try std.testing.expectEqualStrings("backend", table.name(slot));

    table.rollback(gpa, slot);
    table.rollback(gpa, slot);

    const inserted = try table.insert(gpa, "/work/reused", null);
    try std.testing.expectEqual(@as(u64, 1), core.raw(workspaceIdOf(inserted)));
    try std.testing.expectEqual(@as(u64, 1), core.raw(inserted.tab_id));
}

test "committing a proposal advances the table exactly once" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const initial_revision = table.revision;

    const slot = try table.propose(gpa, "/work/project", null);
    const committed = table.commit(slot);
    table.rollback(gpa, slot);

    try std.testing.expect(table.contains(committed));
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expect(table.revision != initial_revision);
    try std.testing.expectEqual(@as(u64, 2), core.raw(try table.nextTabId()));
}

test "equal paths remain distinct workspaces" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);

    const first = try table.insert(gpa, "/work/project", "frontend");
    const second = try table.insert(gpa, "/work/project", "backend");

    try std.testing.expect(!std.meta.eql(first, second));
    try std.testing.expectEqualStrings("frontend", table.workspaceName(first.workspace).?);
    try std.testing.expectEqualStrings("backend", table.workspaceName(second.workspace).?);
    try std.testing.expectEqualStrings(table.workspacePath(first.workspace).?, table.workspacePath(second.workspace).?);
}

test "removal keeps list order and the stable predecessor" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);

    const first = workspaceIdOf(try table.insert(gpa, "/work/first", null));
    const second = workspaceIdOf(try table.insert(gpa, "/work/second", null));
    const third = workspaceIdOf(try table.insert(gpa, "/work/third", null));

    try std.testing.expectEqual(first, table.previousWorkspace(second).?);
    try std.testing.expect(table.remove(gpa, second));
    try std.testing.expectEqual(third, table.previousWorkspace(first).?);
    try std.testing.expect(!table.remove(gpa, second));
}

test "list and tab projections borrow the table" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const location = try table.insert(gpa, "/work/project", "agents");

    var entries: [capacity]core.WorkspaceListEntry = undefined;
    const list = table.listEntries(&entries);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("agents", list[0].name);
    try std.testing.expectEqualStrings("/work/project", list[0].path);

    var descriptors_storage: [max_tabs]core.TabDescriptor = undefined;
    const snapshot = table.descriptors(location.workspace, &descriptors_storage).?;
    try std.testing.expectEqualStrings("agents", snapshot.name);
    try std.testing.expectEqual(@as(usize, 1), snapshot.tabs.len);
}

test "moving and removing tabs follow list revision rules" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const initial = try table.insert(gpa, "/work/project", null);
    const slot = table.slotOf(initial.workspace).?;
    const logs_id = try table.nextTabId();
    _ = try table.addTab(slot, logs_id, "logs");
    table.recordTabCreated(logs_id);
    const logs: core.TabLocation = .{ .workspace = initial.workspace, .tab_id = logs_id };
    try std.testing.expectEqualStrings("logs", table.tabLabel(logs).?);

    const before_move = table.revision;
    try std.testing.expectEqual(@as(u16, 0), try table.moveTab(logs, .{ .direction = .previous }));
    try std.testing.expectEqual(logs_id, table.defaultTab(initial.workspace).?);
    try std.testing.expectEqual(before_move, table.revision);

    const before_remove = table.revision;
    const first_removal = table.removeTab(gpa, initial).?;
    try std.testing.expect(!first_removal.workspace_removed);
    try std.testing.expectEqualDeep(initial, first_removal.location);
    try std.testing.expectEqual(before_remove + 1, table.revision);

    const before_final_remove = table.revision;
    const final_removal = table.removeTab(gpa, logs).?;
    try std.testing.expect(final_removal.workspace_removed);
    try std.testing.expect(table.revision != before_final_remove);
    try std.testing.expectEqual(@as(usize, 0), table.count);
}

test "closing a workspace returns the predecessor in list order" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const first = try table.insert(gpa, "/work/first", null);
    const second = try table.insert(gpa, "/work/second", null);
    const third = try table.insert(gpa, "/work/third", null);

    const middle = table.removeTab(gpa, second).?;
    try std.testing.expect(middle.workspace_removed);
    try std.testing.expectEqual(workspaceIdOf(first), middle.previous_workspace.?);

    const wrapped = table.removeTab(gpa, first).?;
    try std.testing.expectEqual(workspaceIdOf(third), wrapped.previous_workspace.?);

    const last = table.removeTab(gpa, third).?;
    try std.testing.expect(last.workspace_removed);
    try std.testing.expect(last.previous_workspace == null);
}

test "removing a missing tab leaves the table unchanged" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const existing = try table.insert(gpa, "/work/project", null);
    const revision = table.revision;
    const missing: core.TabLocation = .{ .workspace = existing.workspace, .tab_id = try core.tab(999) };

    try std.testing.expect(table.removeTab(gpa, missing) == null);
    try std.testing.expect(table.contains(existing));
    try std.testing.expectEqual(revision, table.revision);
}

test "workspace names derive from the path until an explicit rename within the label limit" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const location = try table.insert(gpa, "/work/telar", null);
    const root = try table.insert(gpa, "/", null);
    const before = table.revision;

    try std.testing.expectEqualStrings("telar", table.workspaceName(location.workspace).?);
    try std.testing.expectEqualStrings("/", table.workspaceName(root.workspace).?);
    try table.rename(location.workspace, "agents");
    try std.testing.expectEqualStrings("agents", table.workspaceName(location.workspace).?);
    try std.testing.expect(table.revision != before);
    try std.testing.expectError(error.InvalidWorkspaceName, table.rename(location.workspace, ""));

    const accepted: [core.max_tab_label_bytes]u8 = @splat('a');
    const oversized: [core.max_tab_label_bytes + 1]u8 = @splat('x');
    try table.rename(location.workspace, &accepted);
    try std.testing.expectEqualSlices(u8, &accepted, table.workspaceName(location.workspace).?);
    try std.testing.expectError(error.InvalidWorkspaceName, table.rename(location.workspace, &oversized));
    try std.testing.expectEqualSlices(u8, &accepted, table.workspaceName(location.workspace).?);
}

test "workspaces reject paths that cannot cross the runtime protocol" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const oversized: [core.max_cwd_bytes + 1]u8 = @splat('x');

    try std.testing.expectError(error.InvalidWorkspacePath, table.insert(gpa, "", null));
    try std.testing.expectError(error.InvalidWorkspacePath, table.insert(gpa, "bad\x00path", null));
    try std.testing.expectError(error.InvalidWorkspacePath, table.insert(gpa, &oversized, null));
    try std.testing.expectEqual(@as(usize, 0), table.count);
}

test "renaming a tab validates the label and changes only that tab" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const first = try table.insert(gpa, "/work/telar", null);
    const slot = table.slotOf(first.workspace).?;
    const logs: core.TabLocation = .{ .workspace = first.workspace, .tab_id = try core.tab(2) };
    _ = try table.addTab(slot, logs.tab_id, "logs");

    try table.renameTab(logs, "server");
    try std.testing.expectEqualStrings("server", table.tabLabel(logs).?);
    try std.testing.expectEqualStrings("", table.tabLabel(first).?);
    try std.testing.expectError(error.InvalidTabLabel, table.renameTab(logs, ""));

    const oversized: [core.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, table.renameTab(logs, &oversized));
    try std.testing.expectEqualStrings("server", table.tabLabel(logs).?);
    try std.testing.expectError(error.TabNotFound, table.renameTab(.{ .workspace = first.workspace, .tab_id = try core.tab(999) }, "missing"));

    try table.renameTab(first, "main");
    try std.testing.expectEqualStrings("main", table.tabLabel(first).?);
}

test "tabs are created, described and bounded per workspace" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const first = try table.insert(gpa, "/work/telar", null);
    const slot = table.slotOf(first.workspace).?;

    try std.testing.expectEqual(@as(u16, 1), try table.addTab(slot, try core.tab(2), "logs"));
    try std.testing.expectEqual(@as(u16, 2), try table.addTab(slot, try core.tab(3), ""));

    var storage: [max_tabs]core.TabDescriptor = undefined;
    const snapshot = table.descriptors(first.workspace, &storage).?;
    try std.testing.expectEqual(@as(usize, 3), snapshot.tabs.len);
    try std.testing.expectEqualStrings("logs", snapshot.tabs[1].label);
    try std.testing.expectEqualStrings("", snapshot.tabs[2].label);

    for (4..max_tabs + 1) |raw_id| {
        _ = try table.addTab(slot, try core.tab(raw_id), "tab");
    }
    try std.testing.expectEqual(@as(u8, max_tabs), table.tab_count[slot]);
    try std.testing.expectError(error.TabLimitReached, table.addTab(slot, try core.tab(max_tabs + 1), "overflow"));
    try std.testing.expectEqual(@as(u8, max_tabs), table.tab_count[slot]);
}

test "anchored tab moves preserve the order and identity of every intervening tab" {
    const gpa = std.testing.allocator;
    const cases = .{
        .{ 1, 4, .previous, .{ 2, 3, 1, 4 }, 2 },
        .{ 1, 4, .next, .{ 2, 3, 4, 1 }, 3 },
        .{ 4, 1, .previous, .{ 4, 1, 2, 3 }, 0 },
        .{ 4, 1, .next, .{ 1, 4, 2, 3 }, 1 },
        .{ 2, 3, .next, .{ 1, 3, 2, 4 }, 2 },
        .{ 3, 2, .previous, .{ 1, 3, 2, 4 }, 1 },
        .{ 2, 3, .previous, .{ 1, 2, 3, 4 }, 1 },
        .{ 2, 2, .next, .{ 1, 2, 3, 4 }, 1 },
    };
    inline for (cases) |case| {
        const table = try testingTable();
        defer destroyTestingTable(table);
        const first = try table.insert(gpa, "/work/telar", null);
        const slot = table.slotOf(first.workspace).?;
        for (2..5) |id| {
            _ = try table.addTab(slot, try core.tab(id), "");
        }

        const moved = try table.moveTab(.{ .workspace = first.workspace, .tab_id = try core.tab(case[0]) }, .{ .relative_to = try core.tab(case[1]), .direction = case[2] });
        try std.testing.expectEqual(@as(u16, case[4]), moved);
        inline for (case[3], 0..) |id, index| {
            try std.testing.expectEqual(try core.tab(id), table.tab_id[slot][index]);
        }
    }
}

test "a missing move anchor leaves the workspace untouched" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const first = try table.insert(gpa, "/work/telar", null);
    const slot = table.slotOf(first.workspace).?;
    _ = try table.addTab(slot, try core.tab(2), "logs");

    try std.testing.expectError(error.TabNotFound, table.moveTab(first, .{ .relative_to = try core.tab(99), .direction = .next }));
    try std.testing.expectEqual(first.tab_id, table.defaultTab(first.workspace).?);
    try std.testing.expectEqual(@as(u8, 2), table.tab_count[slot]);
}

test "a failed insertion preserves identities and revision" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const initial_revision = table.revision;
    const oversized_name: [core.max_tab_label_bytes + 1]u8 = @splat('x');

    try std.testing.expectError(error.InvalidWorkspaceName, table.insert(gpa, "/work/rejected", &oversized_name));
    try std.testing.expectEqual(@as(usize, 0), table.count);
    try std.testing.expectEqual(initial_revision, table.revision);

    const inserted = try table.insert(gpa, "/work/accepted", null);
    try std.testing.expectEqual(@as(u64, 1), core.raw(workspaceIdOf(inserted)));
    try std.testing.expectEqual(@as(u64, 1), core.raw(inserted.tab_id));
}

test "the table rejects workspaces beyond its fixed capacity" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);

    for (0..capacity) |_| {
        _ = try table.insert(gpa, "/work/project", null);
    }

    const full_revision = table.revision;
    try std.testing.expectError(error.WorkspaceLimitReached, table.insert(gpa, "/work/overflow", null));
    try std.testing.expectEqual(@as(usize, capacity), table.count);
    try std.testing.expectEqual(full_revision, table.revision);
}
