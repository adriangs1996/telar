const ConfigType = @import("../config/SoundPolicy.zig");
const AgentSound = @import("telar-core").AgentSound;
const playback_support = @import("sound_playback_support.zig");
const std = @import("std");
const Snapshot = @import("SoundSnapshot.zig");
const SoundPlayback = @This();

configuration: ConfigType,
active: bool = false,
queued: ?AgentSound = null,

/// Creates an idle playback queue with one validated configuration.
///
/// ```zig
/// var playback = SoundPlayback.init(.{});
/// ```
pub fn init(configuration: ConfigType) SoundPlayback {
    return .{ .configuration = configuration };
}

/// Applies current sound policy and starts or coalesces one request.
///
/// ```zig
/// const outcome = playback.request(.needs_input);
/// ```
pub fn request(playback: *SoundPlayback, kind: AgentSound) playback_support.RequestOutcome {
    if (!playback.configuration.allows(kind)) {
        return .ignored;
    }

    if (playback.active) {
        playback.queued = playback_support.coalesce(playback.queued, kind);
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
pub fn complete(playback: *SoundPlayback) ?AgentSound {
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
pub fn schedulingFailed(playback: *SoundPlayback) void {
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
pub fn configure(playback: *SoundPlayback, configuration: ConfigType) void {
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
pub fn snapshot(playback: *const SoundPlayback) Snapshot {
    return .{
        .configuration = playback.configuration,
        .active = playback.active,
        .queued = playback.queued,
    };
}
