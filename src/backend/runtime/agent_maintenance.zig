//! The one-second maintenance tick expires stale agent evidence and starts
//! the periodic observation work: the session checkpoint, one Git probe,
//! one session-name probe, the idle engine check and capture expiry.

const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Sources = @import("Sources.zig");
const agent_rename = @import("agent_rename.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const suggest_command = @import("suggest_command.zig");
const workspace_git = @import("workspace_git.zig");

/// Rearms the tick and runs one maintenance pass.
///
/// ```zig
/// try agent_maintenance.tick(model, result);
/// ```
pub fn tick(model: *RuntimeModel, result: anyerror!void) !void {
    if (result) |_| {
        var sources = Sources.init(model.io, model.select);
        try sources.waitForAgentMaintenance();
        _ = model.agents.expire(std.Io.Timestamp.now(model.io, .real).toMilliseconds());
    } else |_| {}

    try session_checkpoint.start(model);
    workspace_git.start(model);
    agent_rename.start(model);
    suggest_command.stopIdleEngine(model);
    model.resources.proxy.expireCaptures(std.Io.Timestamp.now(model.io, .real).toMilliseconds(), model.resources.pluginService());
}
