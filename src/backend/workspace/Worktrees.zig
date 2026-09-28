const core = @import("telar-core");
const std = @import("std");
const WorktreeRegistration = @import("WorktreeRegistration.zig");
const RegisteredWorktree = @import("RegisteredWorktree.zig");
/// The Git linked worktrees the runtime tracks, one row per worktree: where
/// it lives, the workspace it hangs from, the workspace holding its tabs once
/// something ran there, the task it serves and its last Git and command
/// observations. Rows keep their slot for life, so slot order is list order.
const Worktrees = @This();

pub const capacity = core.max_worktree_entries;
const Rows = std.bit_set.IntegerBitSet(capacity);

id: [capacity]core.WorktreeId = @splat(.invalid),
path: [capacity][]u8 = undefined,
source: [capacity]core.WorkspaceId = @splat(.invalid),
/// The workspace holding the worktree's tabs; null until the first launch
/// and again after its last tab closes.
workspace: [capacity]?core.WorkspaceId = @splat(null),
created_by: [capacity]?core.PaneId = @splat(null),
origin: [capacity]core.WorktreeOrigin = @splat(.telar),
state: [capacity]core.WorktreeState = @splat(.active),
branch: [capacity][core.max_git_branch_bytes]u8 = undefined,
branch_len: [capacity]u8 = @splat(0),
base: [capacity][core.max_git_branch_bytes]u8 = undefined,
base_len: [capacity]u8 = @splat(0),
title: [capacity][core.max_worktree_title_bytes]u8 = undefined,
title_len: [capacity]u8 = @splat(0),
brief: [capacity][core.max_worktree_brief_bytes]u8 = undefined,
brief_len: [capacity]u16 = @splat(0),
/// The machine that dispatched the worktree here; empty when none did.
dispatched_from: [capacity][core.MachineProfile.max_label_bytes]u8 = undefined,
dispatched_from_len: [capacity]u8 = @splat(0),
diff_added: [capacity]u32 = @splat(0),
diff_removed: [capacity]u32 = @splat(0),
diff_files: [capacity]u32 = @splat(0),
commits_ahead: [capacity]u32 = @splat(0),
git_checked_at_ms: [capacity]i64 = @splat(0),
git_dirty: [capacity]bool = @splat(false),
/// Whether a probe ever saw work in the worktree, so a later clean result
/// reads as integrated rather than as not started.
had_changes: [capacity]bool = @splat(false),
probe_failures: [capacity]u8 = @splat(0),
/// The pane running the last launched command, while it runs.
command_pane: [capacity]?core.PaneId = @splat(null),
command_label: [capacity][core.max_worktree_command_label_bytes]u8 = undefined,
command_label_len: [capacity]u8 = @splat(0),
command_state: [capacity]core.CommandState = @splat(.none),
command_exit: [capacity]i32 = @splat(0),
rows: Rows = .initEmpty(),
count: usize = 0,
index: core.GenericSlotIndex(2 * capacity) = .{},
/// The one worktree whose Git probe is in flight; it survives removal.
git_probe: ?core.WorktreeId = null,
next_id: u64 = 1,

/// Tracks a worktree, or returns the row that already tracks `path`. An
/// existing row keeps its identity; a non-empty title or brief replaces the
/// stored one, so a coordinator can name a worktree an agent created.
///
/// ```zig
/// const registered = try worktrees.register(gpa, .{ .source = workspace, .path = "/src/fix", .branch = "fix" });
/// ```
pub fn register(self: *Worktrees, gpa: std.mem.Allocator, request: WorktreeRegistration) !RegisteredWorktree {
    try validate(request);
    if (self.slotOfPath(request.path)) |slot| {
        self.rename(slot, request.title, request.brief);
        return .{ .id = self.id[slot], .slot = slot, .created = false };
    }

    var free = self.rows.complement().iterator(.{});
    const slot = free.next() orelse return error.WorktreeLimitReached;
    const worktree_id = request.id orelse try core.worktree(self.next_id);
    if (self.index.get(core.raw(worktree_id)) != null) {
        return error.DuplicateWorktreeIdentity;
    }

    self.path[slot] = try gpa.dupe(u8, request.path);
    self.id[slot] = worktree_id;
    self.source[slot] = request.source;
    self.workspace[slot] = null;
    self.created_by[slot] = request.created_by;
    self.origin[slot] = request.origin;
    self.state[slot] = .active;
    self.branch_len[slot] = @intCast(copyText(&self.branch[slot], request.branch));
    self.base_len[slot] = @intCast(copyText(&self.base[slot], request.base));
    self.title_len[slot] = @intCast(copyText(&self.title[slot], request.title));
    self.brief_len[slot] = @intCast(copyText(&self.brief[slot], request.brief));
    self.dispatched_from_len[slot] = @intCast(copyText(&self.dispatched_from[slot], request.dispatched_from));
    self.diff_added[slot] = 0;
    self.diff_removed[slot] = 0;
    self.diff_files[slot] = 0;
    self.commits_ahead[slot] = 0;
    self.git_checked_at_ms[slot] = 0;
    self.git_dirty[slot] = false;
    self.had_changes[slot] = false;
    self.probe_failures[slot] = 0;
    self.command_pane[slot] = null;
    self.command_label_len[slot] = 0;
    self.command_state[slot] = .none;
    self.command_exit[slot] = 0;
    self.rows.set(slot);
    self.index.put(core.raw(worktree_id), slot);
    self.count += 1;
    self.next_id = @max(self.next_id, core.raw(worktree_id) + 1);
    return .{ .id = worktree_id, .slot = slot, .created = true };
}

/// Stops tracking one worktree and releases its path.
///
/// ```zig
/// _ = worktrees.remove(gpa, worktree_id);
/// ```
pub fn remove(self: *Worktrees, gpa: std.mem.Allocator, worktree_id: core.WorktreeId) bool {
    const slot = self.slotOf(worktree_id) orelse return false;
    gpa.free(self.path[slot]);
    self.index.remove(core.raw(worktree_id));
    self.id[slot] = .invalid;
    self.rows.unset(slot);
    self.count -= 1;
    return true;
}

/// Releases every row's path. Example: `worktrees.deinit(gpa);`.
pub fn deinit(self: *Worktrees, gpa: std.mem.Allocator) void {
    var rows = self.rows.iterator(.{});
    while (rows.next()) |slot| {
        gpa.free(self.path[slot]);
    }

    self.* = .{};
}

/// Example: `const slot = worktrees.slotOf(worktree_id) orelse return error.WorktreeNotFound;`.
pub fn slotOf(self: *const Worktrees, worktree_id: core.WorktreeId) ?usize {
    return self.index.get(core.raw(worktree_id));
}

/// The row whose checkout is exactly `path`.
/// Example: `const slot = worktrees.slotOfPath("/src/fix") orelse return;`.
pub fn slotOfPath(self: *const Worktrees, path: []const u8) ?usize {
    var rows = self.rows.iterator(.{});
    while (rows.next()) |slot| {
        if (std.mem.eql(u8, self.path[slot], path)) {
            return slot;
        }
    }

    return null;
}

/// The row whose checkout contains `path`, preferring the deepest checkout
/// when worktrees nest.
///
/// ```zig
/// const slot = worktrees.slotContaining("/src/fix/lib/a.zig") orelse return;
/// ```
pub fn slotContaining(self: *const Worktrees, path: []const u8) ?usize {
    var best: ?usize = null;
    var rows = self.rows.iterator(.{});
    while (rows.next()) |slot| {
        const root = self.path[slot];
        if (!contains(root, path)) {
            continue;
        }

        if (best == null or root.len > self.path[best.?].len) {
            best = slot;
        }
    }

    return best;
}

/// The row whose tabs live in `workspace_id`.
/// Example: `const slot = worktrees.slotOfWorkspace(workspace_id) orelse return;`.
pub fn slotOfWorkspace(self: *const Worktrees, workspace_id: core.WorkspaceId) ?usize {
    var rows = self.rows.iterator(.{});
    while (rows.next()) |slot| {
        if (self.workspace[slot] == workspace_id) {
            return slot;
        }
    }

    return null;
}

/// The row whose branch is `branch`, when exactly one row has it.
/// Example: `const slot = worktrees.slotOfBranch("fix") orelse return;`.
pub fn slotOfBranch(self: *const Worktrees, branch: []const u8) ?usize {
    var found: ?usize = null;
    var rows = self.rows.iterator(.{});
    while (rows.next()) |slot| {
        if (!std.mem.eql(u8, self.branchAt(slot), branch)) {
            continue;
        }

        if (found != null) {
            return null;
        }

        found = slot;
    }

    return found;
}

/// The workspace a new worktree found from `workspace_id` hangs from: the
/// source of the worktree `workspace_id` holds, so worktrees never nest.
///
/// ```zig
/// const source = worktrees.sourceFor(pane_workspace);
/// ```
pub fn sourceFor(self: *const Worktrees, workspace_id: core.WorkspaceId) core.WorkspaceId {
    const slot = self.slotOfWorkspace(workspace_id) orelse return workspace_id;
    return self.source[slot];
}

/// Forgets the workspace link of every row held by `workspace_id`, after
/// that workspace lost its last tab. A row whose source workspace went away
/// keeps its stale source; clients list it at the top level. Returns whether
/// a row changed.
///
/// ```zig
/// if (worktrees.releaseWorkspace(workspace_id)) model.workspaces.advanceRevision();
/// ```
pub fn releaseWorkspace(self: *Worktrees, workspace_id: core.WorkspaceId) bool {
    var changed = false;
    var rows = self.rows.iterator(.{});
    while (rows.next()) |slot| {
        if (self.workspace[slot] == workspace_id) {
            self.workspace[slot] = null;
            changed = true;
        }
    }

    return changed;
}

/// Records that `pane_id` now runs `label` in the worktree at `slot`.
/// Example: `worktrees.startCommand(slot, pane.id, "claude");`.
pub fn startCommand(self: *Worktrees, slot: usize, pane_id: core.PaneId, label: []const u8) void {
    self.command_pane[slot] = pane_id;
    self.command_label_len[slot] = @intCast(copyText(&self.command_label[slot], label));
    self.command_state[slot] = .running;
    self.command_exit[slot] = 0;
}

/// Records the exit of the command a row tracks. Returns whether `pane_id`
/// was that command.
///
/// ```zig
/// if (worktrees.finishCommand(pane.id, 1)) model.workspaces.advanceRevision();
/// ```
pub fn finishCommand(self: *Worktrees, pane_id: core.PaneId, exit_code: i32) bool {
    var rows = self.rows.iterator(.{});
    while (rows.next()) |slot| {
        if (self.command_pane[slot] != pane_id) {
            continue;
        }

        self.command_pane[slot] = null;
        self.command_state[slot] = .exited;
        self.command_exit[slot] = exit_code;
        return true;
    }

    return false;
}

/// Writes the tracked worktrees in list order. Slices borrow the table.
///
/// ```zig
/// var entries: [Worktrees.capacity]core.WorktreeListEntry = undefined;
/// const list = worktrees.listEntries(&entries);
/// ```
pub fn listEntries(self: *const Worktrees, output: *[capacity]core.WorktreeListEntry) []const core.WorktreeListEntry {
    var len: usize = 0;
    var rows = self.rows.iterator(.{});
    while (rows.next()) |slot| {
        output[len] = .{
            .worktree = self.id[slot],
            .source = self.source[slot],
            .workspace = self.workspace[slot],
            .created_by = self.created_by[slot],
            .origin = self.origin[slot],
            .state = self.state[slot],
            .path = self.path[slot],
            .branch = self.branchAt(slot),
            .base = self.baseAt(slot),
            .title = self.titleAt(slot),
            .brief = self.briefAt(slot),
            .dispatched_from = self.dispatchedFromAt(slot),
            .diff_added = self.diff_added[slot],
            .diff_removed = self.diff_removed[slot],
            .diff_files = self.diff_files[slot],
            .commits_ahead = self.commits_ahead[slot],
            .command_label = self.commandLabelAt(slot),
            .command_state = self.command_state[slot],
            .command_exit = self.command_exit[slot],
        };
        len += 1;
    }

    return output[0..len];
}

pub fn branchAt(self: *const Worktrees, slot: usize) []const u8 {
    return self.branch[slot][0..self.branch_len[slot]];
}

pub fn baseAt(self: *const Worktrees, slot: usize) []const u8 {
    return self.base[slot][0..self.base_len[slot]];
}

pub fn titleAt(self: *const Worktrees, slot: usize) []const u8 {
    return self.title[slot][0..self.title_len[slot]];
}

pub fn briefAt(self: *const Worktrees, slot: usize) []const u8 {
    return self.brief[slot][0..self.brief_len[slot]];
}

pub fn dispatchedFromAt(self: *const Worktrees, slot: usize) []const u8 {
    return self.dispatched_from[slot][0..self.dispatched_from_len[slot]];
}

pub fn commandLabelAt(self: *const Worktrees, slot: usize) []const u8 {
    return self.command_label[slot][0..self.command_label_len[slot]];
}

/// The name a task goes by: its title, or its branch without one.
/// Example: `const name = worktrees.displayName(slot);`.
pub fn displayName(self: *const Worktrees, slot: usize) []const u8 {
    if (self.title_len[slot] != 0) {
        return self.titleAt(slot);
    }

    return self.branchAt(slot);
}

fn rename(self: *Worktrees, slot: usize, title_value: []const u8, brief_value: []const u8) void {
    if (title_value.len != 0) {
        self.title_len[slot] = @intCast(copyText(&self.title[slot], title_value));
    }

    if (brief_value.len != 0) {
        self.brief_len[slot] = @intCast(copyText(&self.brief[slot], brief_value));
    }
}

fn validate(request: WorktreeRegistration) !void {
    if (request.source == .invalid) {
        return error.InvalidWorkspaceId;
    }

    if (request.path.len == 0 or request.path.len > core.max_cwd_bytes or !std.fs.path.isAbsolutePosix(request.path)) {
        return error.InvalidWorktreePath;
    }

    if (std.mem.indexOfScalar(u8, request.path, 0) != null) {
        return error.InvalidWorktreePath;
    }

    const within = request.branch.len != 0 and request.branch.len <= core.max_git_branch_bytes and
        request.base.len <= core.max_git_branch_bytes and
        request.title.len <= core.max_worktree_title_bytes and
        request.brief.len <= core.max_worktree_brief_bytes and
        request.dispatched_from.len <= core.MachineProfile.max_label_bytes;
    if (!within) {
        return error.InvalidWorktreeText;
    }
}

fn copyText(storage: []u8, value: []const u8) usize {
    const len = @min(value.len, storage.len);
    @memcpy(storage[0..len], value[0..len]);
    return len;
}

/// Whether `path` is `root` or lies beneath it.
fn contains(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) {
        return false;
    }

    return path.len == root.len or path[root.len] == '/' or std.mem.endsWith(u8, root, "/");
}

fn testingTable() !*Worktrees {
    const table = try std.testing.allocator.create(Worktrees);
    table.* = .{};
    return table;
}

fn destroyTestingTable(self: *Worktrees) void {
    self.deinit(std.testing.allocator);
    std.testing.allocator.destroy(self);
}

test "a path registers once and a later registration renames it" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const source: core.WorkspaceId = @enumFromInt(3);

    const first = try table.register(gpa, .{
        .source = source,
        .path = "/src/telar-worktrees/fix",
        .branch = "fix",
        .base = "main",
    });
    const again = try table.register(gpa, .{
        .source = source,
        .path = "/src/telar-worktrees/fix",
        .branch = "fix",
        .title = "Fix tabs",
    });

    try std.testing.expect(first.created);
    try std.testing.expect(!again.created);
    try std.testing.expectEqual(first.id, again.id);
    try std.testing.expectEqualStrings("Fix tabs", table.displayName(first.slot));
    try std.testing.expectEqualStrings("main", table.baseAt(first.slot));
    try std.testing.expectEqual(@as(usize, 1), table.count);
}

test "containment prefers the deepest checkout and never matches a sibling prefix" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const source: core.WorkspaceId = @enumFromInt(1);

    const outer = try table.register(gpa, .{
        .source = source,
        .path = "/w/fix",
        .branch = "fix",
    });
    const inner = try table.register(gpa, .{
        .source = source,
        .path = "/w/fix/nested",
        .branch = "nested",
    });

    try std.testing.expectEqual(outer.slot, table.slotContaining("/w/fix/src").?);
    try std.testing.expectEqual(inner.slot, table.slotContaining("/w/fix/nested/a").?);
    try std.testing.expect(table.slotContaining("/w/fixed") == null);
    try std.testing.expectEqual(outer.slot, table.slotOfBranch("fix").?);
}

test "commands and workspace links follow their panes" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const source: core.WorkspaceId = @enumFromInt(1);
    const child: core.WorkspaceId = @enumFromInt(2);
    const registered = try table.register(gpa, .{
        .source = source,
        .path = "/w/fix",
        .branch = "fix",
    });

    table.workspace[registered.slot] = child;
    table.startCommand(registered.slot, @enumFromInt(9), "zig");
    try std.testing.expectEqual(registered.slot, table.slotOfWorkspace(child).?);
    try std.testing.expect(!table.finishCommand(@enumFromInt(8), 0));
    try std.testing.expect(table.finishCommand(@enumFromInt(9), 1));
    try std.testing.expectEqual(core.CommandState.exited, table.command_state[registered.slot]);
    try std.testing.expectEqual(@as(i32, 1), table.command_exit[registered.slot]);

    try std.testing.expect(table.releaseWorkspace(child));
    try std.testing.expect(table.workspace[registered.slot] == null);

    var entries: [capacity]core.WorktreeListEntry = undefined;
    try std.testing.expectEqual(@as(usize, 1), table.listEntries(&entries).len);
    try std.testing.expect(table.remove(gpa, registered.id));
    try std.testing.expectEqual(@as(usize, 0), table.listEntries(&entries).len);
}

test "registration rejects relative paths, empty branches and exhausted capacity" {
    const gpa = std.testing.allocator;
    const table = try testingTable();
    defer destroyTestingTable(table);
    const source: core.WorkspaceId = @enumFromInt(1);

    try std.testing.expectError(error.InvalidWorktreePath, table.register(gpa, .{ .source = source, .path = "fix", .branch = "fix" }));
    try std.testing.expectError(error.InvalidWorktreeText, table.register(gpa, .{ .source = source, .path = "/w/fix", .branch = "" }));

    var buffer: [32]u8 = undefined;
    for (0..capacity) |index| {
        const path = try std.fmt.bufPrint(&buffer, "/w/{d}", .{index});
        _ = try table.register(gpa, .{ .source = source, .path = path, .branch = "b" });
    }

    try std.testing.expectError(error.WorktreeLimitReached, table.register(gpa, .{ .source = source, .path = "/w/over", .branch = "b" }));
}
