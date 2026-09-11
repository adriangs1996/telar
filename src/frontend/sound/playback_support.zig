//! Fixed-depth playback state for one disposable client.

const std = @import("std");
const types = @import("types.zig");

pub const Config = types.Config;
pub const Kind = types.Kind;

pub const RequestOutcome = union(enum) {
    ignored,
    queued,
    start: Kind,
};

pub const Snapshot = @import("Snapshot.zig");

pub const Playback = @import("Playback.zig");

pub fn coalesce(current: ?Kind, incoming: Kind) Kind {
    if (current == .needs_input or incoming == .needs_input) {
        return .needs_input;
    }

    return .ready;
}

test "playback starts one worker and coalesces one queued priority" {
    var playback = Playback.init(.{});

    try std.testing.expectEqualDeep(RequestOutcome{ .start = .ready }, playback.request(.ready));
    try std.testing.expect(playback.request(.ready) == .queued);
    try std.testing.expect(playback.request(.needs_input) == .queued);
    try std.testing.expectEqual(Snapshot{
        .configuration = .{},
        .active = true,
        .queued = .needs_input,
    }, playback.snapshot());

    try std.testing.expectEqual(Kind.needs_input, playback.complete().?);
    try std.testing.expectEqual(Snapshot{
        .configuration = .{},
        .active = true,
        .queued = null,
    }, playback.snapshot());

    try std.testing.expect(playback.complete() == null);
    try std.testing.expect(!playback.snapshot().active);
}

test "playback configuration filters requests and queued work" {
    var playback = Playback.init(.{});
    _ = playback.request(.ready);
    _ = playback.request(.ready);

    playback.configure(.{ .ready = false });

    try std.testing.expectEqual(Snapshot{
        .configuration = .{ .ready = false },
        .active = true,
        .queued = null,
    }, playback.snapshot());
    try std.testing.expect(playback.complete() == null);
    try std.testing.expect(playback.request(.ready) == .ignored);
    try std.testing.expectEqualDeep(
        RequestOutcome{ .start = .needs_input },
        playback.request(.needs_input),
    );

    playback.schedulingFailed();
    playback.configure(.{ .enabled = false });

    try std.testing.expect(playback.request(.needs_input) == .ignored);
}

test "a scheduling failure releases the active playback token" {
    var playback = Playback.init(.{});
    _ = playback.request(.ready);

    playback.schedulingFailed();

    try std.testing.expect(!playback.snapshot().active);
    try std.testing.expectEqualDeep(
        RequestOutcome{ .start = .ready },
        playback.request(.ready),
    );
}
