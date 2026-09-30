//! The one-second maintenance tick expires stale agent evidence and starts
//! the periodic observation work: the session checkpoint, one Git probe,
//! one worktree detection, one session-name probe, the idle engine check,
//! capture expiry and the proxy's limit reports.
const client_connection = @import("client_connection.zig");
const agent_hooks = @import("agent_hooks.zig");
const agent_status = @import("agent_status.zig");

const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Sources = @import("Sources.zig");
const agent_rename = @import("agent_rename.zig");
const proxy_limits = @import("proxy_limits.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const suggest_command = @import("suggest_command.zig");
const workspace_git = @import("workspace_git.zig");
const worktree_git = @import("worktree_git.zig");
const worktree_detection = @import("worktree_detection.zig");

/// Rearms the tick and runs one maintenance pass.
///
/// ```zig
/// try agent_maintenance.tick(model, result);
/// ```
pub fn tick(model: *RuntimeModel, result: anyerror!void) !void {
    if (result) |_| {
        var sources = Sources.init(model.io, model.select);
        try sources.waitForAgentMaintenance();
        _ = agent_status.expire(model, std.Io.Timestamp.now(model.io, .real).toMilliseconds());
    } else |_| {}

    session_checkpoint.start(model);
    model.resources.log.trim(model.io);
    client_connection.expireHandshakes(model);
    agent_hooks.expireParked(model);
    workspace_git.start(model);
    worktree_git.start(model);
    worktree_detection.start(model);
    agent_rename.start(model);
    suggest_command.stopIdleEngine(model);
    model.resources.proxy.expireCaptures(std.Io.Timestamp.now(model.io, .real).toMilliseconds(), model.resources.pluginService());
    proxy_limits.report(model);
}
