const id = @import("../id.zig");
const TerminalSize = @import("../TerminalSize.zig");
const Launch = @import("../Launch.zig");
/// Starts a command in a tracked worktree without attaching the sender. The
/// first launch creates the worktree's workspace; later launches add tabs.
/// The launch working directory is always the worktree's checkout.
const LaunchWorktree = @This();

request_id: id.RequestId,
worktree: id.WorktreeId,
label: []const u8 = "",
size: TerminalSize,
launch: Launch,
