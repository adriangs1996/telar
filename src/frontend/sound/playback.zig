//! Fixed-depth playback state for one disposable client.

const std = @import("std");
const types = @import("types.zig");

const Config = types.Config;
const Kind = types.Kind;

pub const RequestOutcome = union(enum) {
    ignored,
    queued,
    start: Kind,
};

pub const Snapshot = struct {
    configuration: Config,
    active: bool,
    queued: ?Kind,
};

pub const Playback = struct {
    configuration: Config,
    active: bool = false,
    queued: ?Kind = null,

    /// Creates an idle playback queue with one validated configuration.
    ///
    /// ```zig
    /// var playback = Playback.init(.{});
    /// ```
    pub fn init(configuration: Config) Playback {
        return .{ .configuration = configuration };
    }

    /// Applies current sound policy and starts or coalesces one request.
    ///
    /// ```zig
    /// const outcome = playback.request(.needs_input);
    /// ```
    pub fn request(playback: *Playback, kind: Kind) RequestOutcome {
        if (!playback.configuration.allows(kind)) {
            return .ignored;
        }

        if (playback.active) {
            playback.queued = coalesce(playback.queued, kind);
            return .queued;
        }

        std.debug.assert(playback.queued == null);
        playback.active = true;

        return .{ .start = kind };
    }

    /// Releases one completed worker and claims the coalesced successor.
    ///
    /// ```zig
    /// const next = playback.complete();
    /// ```
    pub fn complete(playback: *Playback) ?Kind {
        std.debug.assert(playback.active);
        playback.active = false;
        const queued = playback.queued;
        playback.queued = null;

        const kind = queued orelse return null;
        if (!playback.configuration.allows(kind)) {
            return null;
        }

        playback.active = true;

        return kind;
    }

    /// Releases the token reserved before a worker failed to schedule.
    ///
    /// ```zig
    /// playback.schedulingFailed();
    /// ```
    pub fn schedulingFailed(playback: *Playback) void {
        std.debug.assert(playback.active);
        std.debug.assert(playback.queued == null);
        playback.active = false;
    }

    /// Replaces sound policy and removes queued work it no longer permits.
    /// An already running host command remains active until completion.
    ///
    /// ```zig
    /// playback.configure(.{ .enabled = false });
    /// ```
    pub fn configure(playback: *Playback, configuration: Config) void {
        playback.configuration = configuration;
        const queued = playback.queued orelse return;
        if (!configuration.allows(queued)) {
            playback.queued = null;
        }
    }

    /// Returns a value copy of the physical playback state.
    ///
    /// ```zig
    /// const state = playback.snapshot();
    /// ```
    pub fn snapshot(playback: *const Playback) Snapshot {
        return .{
            .configuration = playback.configuration,
            .active = playback.active,
            .queued = playback.queued,
        };
    }
};

fn coalesce(current: ?Kind, incoming: Kind) Kind {
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
