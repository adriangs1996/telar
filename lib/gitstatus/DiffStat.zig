/// What a worktree holds beyond its base: lines added and removed and files
/// touched against the merge base, local changes included, and commits ahead.
const DiffStat = @This();

added: u32 = 0,
removed: u32 = 0,
files: u32 = 0,
commits_ahead: u32 = 0,
