/// The fields of Claude Code's worktree hooks telar reads.
const WorktreeHookInput = @This();

hook_event_name: []const u8 = "",
cwd: []const u8 = "",
/// The worktree name Claude Code chose or the user passed.
name: []const u8 = "",
/// The checkout `WorktreeRemove` asks to remove.
worktree_path: []const u8 = "",
