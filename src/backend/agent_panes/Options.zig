const PaneId = @import("telar-core").PaneId;

pane_id: PaneId,
pane_generation: u64,
cwd: []const u8,
restore_conversation: ?@import("telar-core").RecentConversation = null,
// Zig spawn searches its own PATH; env resolves codex in the supplied runtime environment.
arguments: []const []const u8 = &.{ "/usr/bin/env", "codex", "app-server", "--listen", "stdio://" },
startup_timeout_ms: u32 = 15_000,
environment: @import("std").process.Environ = .empty,
