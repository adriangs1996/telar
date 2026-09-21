//! Owns the favicon lookups of the workspace list: one bounded file read
//! at a time on the observation path, started only when the adapter has
//! bound a runner, stale results discarded by execution identity. Which
//! workspaces need a lookup is the adapter's knowledge: it holds the
//! sprite page the images land in.

const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const CompletionType = @import("../../completion/FaviconCompletion.zig");
const ImageType = @import("../../completion/FaviconImage.zig");
const RequestType = @import("FaviconRequest.zig");
const Outcome = @import("favicon_outcome.zig").FaviconOutcome;
const TestRunner = @import("FaviconTestRunner.zig");

/// Starts a lookup when no other is in flight and a runner is bound.
/// Returns whether it started; the caller retries later otherwise.
///
/// ```zig
/// if (try request(client, .{ .workspace = id, .cwd = path, .cell = 32 })) markPending();
/// ```
pub fn request(client: *Client, wanted: RequestType) !bool {
    const runner = client.favicon_runner orelse return false;
    if (client.favicons.busy() or wanted.cell == 0 or wanted.cell > ImageType.max_side) {
        return false;
    }

    const id = client.favicons.reserve(wanted.workspace);
    runner.start(.init(.{ .execution_id = id, .workspace = wanted.workspace, .cell = wanted.cell }, wanted.cwd)) catch |err| {
        client.favicons.reset();
        return err;
    };
    return true;
}

/// Lands one worker result: the owned image when it answers the in-flight
/// lookup, `missing` when that lookup found nothing usable, `stale` when
/// it answered no lookup at all. A failed decode logs once; a missing file
/// is silent. The caller owns a returned image.
///
/// ```zig
/// switch (complete(client, completion)) { .image => |image| place(image), else => {} }
/// ```
pub fn complete(client: *Client, completion: CompletionType) Outcome {
    const answered = client.favicons.finish(completion.execution_id);
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
pub fn cancel(client: *Client) void {
    client.favicons.reset();
}

pub const Request = RequestType;
pub const Completion = CompletionType;

test "one lookup runs at a time, stale and cancelled results are released and failures leave the runner idle" {
    var client: Client = undefined;
    client.gpa = std.testing.allocator;
    client.favicons = .{};
    client.favicon_runner = null;
    try std.testing.expect(!try request(&client, .{ .workspace = @enumFromInt(1), .cwd = "/a", .cell = 16 }));

    var runner: TestRunner = .{};
    client.favicon_runner = .{ .context = &runner, .start_fn = TestRunner.start };
    try std.testing.expect(!try request(&client, .{ .workspace = @enumFromInt(1), .cwd = "/a", .cell = 0 }));
    try std.testing.expect(try request(&client, .{ .workspace = @enumFromInt(1), .cwd = "/a", .cell = 16 }));
    try std.testing.expect(!try request(&client, .{ .workspace = @enumFromInt(2), .cwd = "/b", .cell = 16 }));
    try std.testing.expectEqual(@as(usize, 1), runner.started);
    try std.testing.expectEqualStrings("/a", runner.last.?.cwdSlice());
    const first = runner.last.?.execution_id;

    const stale = try std.testing.allocator.create(ImageType);
    stale.* = .{ .side = 16 };
    try std.testing.expect(complete(&client, .{ .execution_id = @enumFromInt(99), .workspace = @enumFromInt(1), .result = stale }) == .stale);
    try std.testing.expect(client.favicons.busy());

    const landed = try std.testing.allocator.create(ImageType);
    landed.* = .{ .side = 16 };
    const owned = complete(&client, .{ .execution_id = first, .workspace = @enumFromInt(1), .result = landed });
    std.testing.allocator.destroy(owned.image);
    try std.testing.expect(!client.favicons.busy());

    try std.testing.expect(try request(&client, .{ .workspace = @enumFromInt(2), .cwd = "/b", .cell = 16 }));
    const second = runner.last.?.execution_id;
    cancel(&client);
    const cancelled = try std.testing.allocator.create(ImageType);
    cancelled.* = .{ .side = 16 };
    try std.testing.expect(complete(&client, .{ .execution_id = second, .workspace = @enumFromInt(2), .result = cancelled }) == .stale);

    try std.testing.expect(try request(&client, .{ .workspace = @enumFromInt(3), .cwd = "/c", .cell = 16 }));
    try std.testing.expect(complete(&client, .{ .execution_id = runner.last.?.execution_id, .workspace = @enumFromInt(3), .result = error.FaviconNotFound }) == .missing);
    try std.testing.expect(complete(&client, .{ .execution_id = @enumFromInt(5), .workspace = @enumFromInt(3), .result = error.InvalidPngData }) == .stale);
    try std.testing.expect(!client.favicons.busy());

    runner.fail = true;
    try std.testing.expectError(error.RunnerUnavailable, request(&client, .{ .workspace = @enumFromInt(4), .cwd = "/d", .cell = 16 }));
    try std.testing.expect(!client.favicons.busy());
}
