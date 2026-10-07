//! Owns the favicon lookups of the workspace list: one bounded file read
//! at a time on the observation path, stale results discarded by execution
//! identity. Which workspaces need a lookup is the adapter's knowledge: it
//! holds the sprite page the images land in and runs the lookup itself.

const favicon_outcome = @import("favicon_outcome.zig");
const std = @import("std");
const limit_reached = @import("../notifications/limit_reached.zig");
const Client = @import("../execution/Client.zig");
const FaviconCompletion = @import("../completion/FaviconCompletion.zig");
const FaviconImage = @import("../completion/FaviconImage.zig");
const FaviconRequest = @import("FaviconRequest.zig");
const FaviconJob = @import("../completion/FaviconJob.zig");
const data = @import("model");

/// Reserves the one lookup slot and returns the job the adapter runs. Null
/// when another lookup is in flight or a cell cannot hold an image; the
/// caller retries later. A job the adapter fails to start is released with
/// `cancel`.
///
/// ```zig
/// const job = request(client, .{ .workspace = id, .cwd = path, .cells = .{ 28, 36, 40 } }) orelse return;
/// ```
pub fn request(model: *data.ClientModel, wanted: FaviconRequest) ?FaviconJob {
    if (model.favicons.busy()) {
        return null;
    }

    for (wanted.cells) |cell| {
        if (cell == 0 or cell > FaviconImage.max_side) {
            return null;
        }
    }

    const id = model.favicons.reserve(wanted.workspace);
    const job: FaviconJob = .{
        .execution_id = id,
        .workspace = wanted.workspace,
        .cells = wanted.cells,
    };
    return job.init(wanted.cwd);
}

/// Lands one worker result: the owned image when it answers the in-flight
/// lookup, `missing` when that lookup found nothing usable, `stale` when
/// it answered no lookup at all. A limit the worker stopped at is reported
/// here, on the loop, even for a stale lookup, since the file reached it
/// all the same; any other failed decode logs once and a missing file is
/// silent. The caller owns a returned image.
///
/// ```zig
/// switch (complete(client, completion)) { .image => |image| place(image), else => {} }
/// ```
pub fn complete(client: *Client, completion: FaviconCompletion) favicon_outcome.FaviconOutcome {
    const answered = client.model.favicons.finish(completion.execution_id);
    if (completion.limit) |reach| {
        limit_reached.report(client, reach);
    }

    const result = completion.result catch |err| {
        if (answered and err != error.FaviconNotFound and completion.limit == null) {
            std.log.scoped(.favicons).warn("favicon of workspace {d} unusable: {s}", .{ @intFromEnum(completion.workspace), @errorName(err) });
        }

        return if (answered) .missing else .stale;
    };
    if (!answered) {
        client.gpa.destroy(result);
        return .stale;
    }

    return .{ .image = result };
}

/// Orphans the in-flight lookup, for example when its workspace left the
/// list; its result is released unread when it lands.
///
/// ```zig
/// cancel(client);
/// ```
pub fn cancel(model: *data.ClientModel) void {
    model.favicons.reset();
}
