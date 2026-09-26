const std = @import("std");
const WorktreeCatalog = @import("WorktreeCatalog.zig");
const ExecutionContext = @This();

writer: *std.Io.Writer,
environ: std.process.Environ,
/// Worktrees for `worktree:` targets; empty when no target names one.
catalog: ?*const WorktreeCatalog = null,
