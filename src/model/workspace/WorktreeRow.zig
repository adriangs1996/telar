const core = @import("telar-core");
const std = @import("std");
const WorktreeInput = @import("WorktreeInput.zig");
/// One tracked worktree in the client's workspace-list replica: what a task
/// card and the peek show about it, in fixed storage.
const WorktreeRow = @This();

/// Bytes of the checkout path kept for the peek header: its tail.
pub const max_path_bytes = 256;

worktree: core.WorktreeId,
source: core.WorkspaceId,
workspace: ?core.WorkspaceId,
/// The pane that delegated the task, usually its coordinator.
created_by: ?core.PaneId = null,
state: core.WorktreeState,
branch: [core.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,
base: [core.max_git_branch_bytes]u8 = undefined,
base_len: u8 = 0,
title: [core.max_worktree_title_bytes]u8 = undefined,
title_len: u8 = 0,
path: [max_path_bytes]u8 = undefined,
path_len: u16 = 0,
diff_added: u32,
diff_removed: u32,
diff_files: u32,
commits_ahead: u32,
command_label: [core.max_worktree_command_label_bytes]u8 = undefined,
command_label_len: u8 = 0,
command_state: core.CommandState,
command_exit: i32,

/// Copies one worktree from the wire, keeping the tail of a long path.
///
/// ```zig
/// const row = WorktreeRow.init(input);
/// ```
pub fn init(input: WorktreeInput) WorktreeRow {
    var row: WorktreeRow = .{
        .worktree = input.worktree,
        .source = input.source,
        .workspace = input.workspace,
        .created_by = input.created_by,
        .state = input.state,
        .diff_added = input.diff_added,
        .diff_removed = input.diff_removed,
        .diff_files = input.diff_files,
        .commits_ahead = input.commits_ahead,
        .command_state = input.command_state,
        .command_exit = input.command_exit,
    };
    row.branch_len = @intCast(copyPrefix(&row.branch, input.branch));
    row.base_len = @intCast(copyPrefix(&row.base, input.base));
    row.title_len = @intCast(copyPrefix(&row.title, input.title));
    row.command_label_len = @intCast(copyPrefix(&row.command_label, input.command_label));
    const tail = input.path[input.path.len -| max_path_bytes..];
    @memcpy(row.path[0..tail.len], tail);
    row.path_len = @intCast(tail.len);
    return row;
}

pub fn branchSlice(self: *const WorktreeRow) []const u8 {
    return self.branch[0..self.branch_len];
}

pub fn baseSlice(self: *const WorktreeRow) []const u8 {
    return self.base[0..self.base_len];
}

pub fn titleSlice(self: *const WorktreeRow) []const u8 {
    return self.title[0..self.title_len];
}

pub fn pathSlice(self: *const WorktreeRow) []const u8 {
    return self.path[0..self.path_len];
}

pub fn commandLabel(self: *const WorktreeRow) []const u8 {
    return self.command_label[0..self.command_label_len];
}

/// The name a task goes by: its title, else its branch.
///
/// ```zig
/// const name = row.displayName();
/// ```
pub fn displayName(self: *const WorktreeRow) []const u8 {
    return if (self.title_len != 0) self.titleSlice() else self.branchSlice();
}

/// The branch without the prefixes agents add to worktree branches.
///
/// ```zig
/// const handle = row.handle(); // "worktree-fix" -> "fix"
/// ```
pub fn handle(self: *const WorktreeRow) []const u8 {
    const branch = self.branchSlice();
    for ([_][]const u8{ "worktree-", "worktree/" }) |prefix| {
        if (std.mem.startsWith(u8, branch, prefix) and branch.len > prefix.len) {
            return branch[prefix.len..];
        }
    }

    return branch;
}

fn copyPrefix(destination: []u8, source: []const u8) usize {
    var len = @min(source.len, destination.len);
    while (len > 0 and len < source.len and (source[len] & 0xc0) == 0x80) {
        len -= 1;
    }

    @memcpy(destination[0..len], source[0..len]);
    return len;
}

test "rows keep the handle, the display name and a path tail" {
    const long_path = "/" ++ "d" ** 300 ++ "/fix";
    const row = WorktreeRow.init(.{
        .worktree = @enumFromInt(1),
        .source = @enumFromInt(2),
        .path = long_path,
        .branch = "worktree-fix",
    });
    try std.testing.expectEqualStrings("fix", row.handle());
    try std.testing.expectEqualStrings("worktree-fix", row.displayName());
    try std.testing.expect(std.mem.endsWith(u8, row.pathSlice(), "/fix"));
    try std.testing.expectEqual(@as(usize, max_path_bytes), row.pathSlice().len);
}
