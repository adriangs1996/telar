//! Owns the favicon lookups of the workspace list: one bounded file read
//! at a time on the observation path, stale results discarded by execution
//! identity. Which workspaces need a lookup is the adapter's knowledge: it
//! holds the sprite page the images land in and runs the lookup itself.

const favicon_outcome = @import("favicon_outcome.zig");
const std = @import("std");
const Client = @import("../AttachedClient.zig");
const FaviconCompletion = @import("../completion/FaviconCompletion.zig");
const FaviconImage = @import("../completion/FaviconImage.zig");
const FaviconRequest = @import("FaviconRequest.zig");
const FaviconJob = @import("../completion/FaviconJob.zig");
const data = @import("model");

/// Reserves the one lookup slot and returns the job the adapter runs. Null
/// when another lookup is in flight or the cell cannot hold an image; the
/// caller retries later. A job the adapter fails to start is released with
/// `cancel`.
///
/// ```zig
/// const job = request(client, .{ .workspace = id, .cwd = path, .cell = 32 }) orelse return;
/// ```
pub fn request(model: *data.ClientModel, wanted: FaviconRequest) ?FaviconJob {
    if (model.favicons.busy() or wanted.cell == 0 or wanted.cell > FaviconImage.max_side) {
        return null;
    }

    const id = model.favicons.reserve(wanted.workspace);
    return .init(.{ .execution_id = id, .workspace = wanted.workspace, .cell = wanted.cell }, wanted.cwd);
}

/// Lands one worker result: the owned image when it answers the in-flight
/// lookup, `missing` when that lookup found nothing usable, `stale` when
/// it answered no lookup at all. A failed decode logs once; a missing file
/// is silent. The caller owns a returned image.
///
/// ```zig
/// switch (complete(client, completion)) { .image => |image| place(image), else => {} }
/// ```
pub fn complete(client: *Client, completion: FaviconCompletion) favicon_outcome.FaviconOutcome {
    const answered = client.model.favicons.finish(completion.execution_id);
    const result = completion.result catch |err| {
        if (answered and err != error.FaviconNotFound) {
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

pub const Request = FaviconRequest;
pub const Completion = FaviconCompletion;

test "one lookup runs at a time and stale and cancelled results are released" {
    var client: Client = undefined;
    client.gpa = std.testing.allocator;
    client.model.favicons = .{};

    try std.testing.expect(request(&client.model, .{ .workspace = @enumFromInt(1), .cwd = "/a", .cell = 0 }) == null);
    const first = request(&client.model, .{ .workspace = @enumFromInt(1), .cwd = "/a", .cell = 16 }).?;
    try std.testing.expect(request(&client.model, .{ .workspace = @enumFromInt(2), .cwd = "/b", .cell = 16 }) == null);
    try std.testing.expectEqualStrings("/a", first.cwdSlice());

    const stale = try std.testing.allocator.create(FaviconImage);
    stale.* = .{ .side = 16 };
    try std.testing.expect(complete(&client, .{ .execution_id = @enumFromInt(99), .workspace = @enumFromInt(1), .result = stale }) == .stale);
    try std.testing.expect(client.model.favicons.busy());

    const landed = try std.testing.allocator.create(FaviconImage);
    landed.* = .{ .side = 16 };
    const owned = complete(&client, .{ .execution_id = first.execution_id, .workspace = @enumFromInt(1), .result = landed });
    std.testing.allocator.destroy(owned.image);
    try std.testing.expect(!client.model.favicons.busy());

    const second = request(&client.model, .{ .workspace = @enumFromInt(2), .cwd = "/b", .cell = 16 }).?;
    cancel(&client.model);
    const cancelled = try std.testing.allocator.create(FaviconImage);
    cancelled.* = .{ .side = 16 };
    try std.testing.expect(complete(&client, .{ .execution_id = second.execution_id, .workspace = @enumFromInt(2), .result = cancelled }) == .stale);

    const third = request(&client.model, .{ .workspace = @enumFromInt(3), .cwd = "/c", .cell = 16 }).?;
    try std.testing.expect(complete(&client, .{ .execution_id = third.execution_id, .workspace = @enumFromInt(3), .result = error.FaviconNotFound }) == .missing);
    try std.testing.expect(complete(&client, .{ .execution_id = @enumFromInt(5), .workspace = @enumFromInt(3), .result = error.InvalidPngData }) == .stale);
    try std.testing.expect(!client.model.favicons.busy());
}
