const std = @import("std");
const core = @import("telar-core");
const ReviewService = @import("../change_review/Service.zig");

pane_id: core.PaneId,
pane_generation: u64,
cwd: []const u8,
restore_conversation: ?core.RecentConversation = null,
// Zig spawn searches its own PATH; env resolves codex in the supplied runtime environment.
arguments: []const []const u8 = &.{ "/usr/bin/env", "codex", "app-server", "--listen", "stdio://" },
startup_timeout_ms: u32 = 15_000,
environment: std.process.Environ = .empty,

review_service: ?*ReviewService = null,
