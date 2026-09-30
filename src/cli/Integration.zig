const HookLayout = @import("HookLayout.zig").HookLayout;
const core = @import("telar-core");
const Integration = @This();

name: []const u8,
settings: core.HookSettings,
events: []const []const u8,
/// Events whose hook must run outside telar panes too, because the agent
/// depends on its answer: creating and removing worktrees.
worktree_events: []const []const u8 = &.{},
timeout_seconds: i64,
layout: HookLayout = .nested,
/// What the user must do beyond installing for the hooks to reach a pane;
/// printed after install. Empty when nothing is needed.
launch_note: []const u8 = "",
