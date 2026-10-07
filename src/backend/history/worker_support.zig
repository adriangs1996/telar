//! Sequential execution of history requests against durable storage.

const core = @import("telar-core");
const std = @import("std");
const model = @import("model.zig");
const QueryOrigin = @import("QueryOrigin.zig");
const Context = @import("Context.zig");
const Pruned = @import("Pruned.zig");
const Store = @import("persistence/Store.zig");
const ImportBatch = @import("ImportBatch.zig");
const SessionStarted = @import("SessionStarted.zig");
const CommandFinished = @import("CommandFinished.zig");

pub const Execution = enum {
    continue_running,
    stop,
};

pub fn superseded(request: model.Request, later: []const model.Request) bool {
    const query = switch (request) {
        .query => |query| query,
        else => return false,
    };
    if (query.origin.close_after_reply or query.offset != 0 or query.snapshot_id != 0 or query.entry_id != 0) {
        return false;
    }

    for (later) |candidate| {
        const newer = switch (candidate) {
            .query => |value| value,
            // Writes and other requests are ordering barriers.
            else => break,
        };
        if (!newer.origin.close_after_reply and newer.offset == 0 and newer.snapshot_id == 0 and newer.entry_id == 0 and
            std.meta.eql(query.origin.client, newer.origin.client) and query.distinct == newer.distinct and
            query.request_id != newer.request_id)
        {
            return true;
        }
    }

    return false;
}

pub fn unavailableResponse(request_id: core.RequestId, origin: QueryOrigin) model.Response {
    return .{ .failed = .{
        .request_id = request_id,
        .origin = origin,
        .message = "history database is unavailable",
    } };
}

pub fn respondPruned(context: Context, pruned: Pruned) void {
    // Response delivery may end when the history consumer closes or cancels its queue; the pruned response owns no buffers to release.
    context.channel.sendResponse(context.io, .{ .pruned = pruned }) catch {};
}

/// Writes one imported session and its commands idempotently. Both SQLite
/// operations use `OR IGNORE`, keyed by deterministic session and sequence.
pub fn writeImportBatch(database: *Store, batch: *const ImportBatch) anyerror!void {
    const session: SessionStarted = .{
        .id = batch.session_id,
        .pane_id = batch.pane_id,
        .location = batch.location,
        .started_at_ms = batch.started_at_ms,
        .workspace_path = @constCast(""),
        .shell = batch.source,
    };
    try database.importSession(&session);

    for (batch.commands, batch.times, 0..) |command, time, index| {
        var value: CommandFinished = .{
            .session_id = batch.session_id,
            .pane_id = batch.pane_id,
            .location = batch.location,
            .sequence = batch.base_sequence + index,
            .started_at_ms = time,
            .duration_ns = 0,
            .exit_code = null,
            .status = .completed,
            .author = .human,
            .cols = 0,
            .rows = 0,
            .command = command,
            .cwd = @constCast(""),
            .workspace_path = @constCast(""),
            .command_truncated = false,
            .output = @constCast(""),
            .output_truncated = false,
            .output_observed = 0,
        };
        try database.importCommand(&value);
    }
}

pub fn elapsedSince(io: std.Io, started: std.Io.Timestamp) u64 {
    return elapsedNs(started, std.Io.Timestamp.now(io, .awake));
}

fn elapsedNs(started: std.Io.Timestamp, finished: std.Io.Timestamp) u64 {
    return @intCast(@max(@as(i96, 0), finished.nanoseconds - started.nanoseconds));
}
