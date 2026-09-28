const HookLayout = @import("HookLayout.zig").HookLayout;
const Integration = @This();

name: []const u8,
settings_environment: ?[]const u8,
settings_directory: []const u8,
settings_file: []const u8,
marker: []const u8,
events: []const []const u8,
/// Events whose hook must run outside telar panes too, because the agent
/// depends on its answer: creating and removing worktrees.
worktree_events: []const []const u8 = &.{},
timeout_seconds: i64,
layout: HookLayout = .nested,
