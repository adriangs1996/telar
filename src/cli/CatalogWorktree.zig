const core = @import("telar-core");
const CatalogWorktree = @This();

id: core.WorktreeId,
source: u64,
workspace: ?u64,
created_by: ?u64,
origin: core.WorktreeOrigin,
state: core.WorktreeState,
path: []const u8,
branch: []const u8,
base: []const u8,
title: []const u8,
brief: []const u8,
/// The machine that dispatched it here; empty when none did.
dispatched_from: []const u8 = "",
diff_added: u32,
diff_removed: u32,
diff_files: u32,
commits_ahead: u32,
command_label: []const u8,
command_state: core.CommandState,
command_exit: i32,

/// The name a task goes by: its title, or its branch without one.
pub fn displayName(self: *const CatalogWorktree) []const u8 {
    return if (self.title.len != 0) self.title else self.branch;
}
