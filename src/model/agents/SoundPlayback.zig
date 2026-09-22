const SoundRequestOutcome = @import("../types/SoundRequestOutcome.zig").SoundRequestOutcome;
const core = @import("telar-core");
const SoundPolicy = @import("../config/SoundPolicy.zig");
const playback_support = @import("sound_playback.zig");
const std = @import("std");
const SoundSnapshot = @import("SoundSnapshot.zig");
const SoundPlayback = @This();

configuration: SoundPolicy,
active: bool = false,
queued: ?core.AgentSound = null,

/// Creates an idle playback queue with one validated configuration.
///
/// ```zig
/// var playback = SoundPlayback.init(.{});
/// ```
pub fn init(configuration: SoundPolicy) SoundPlayback {
    return .{ .configuration = configuration };
}

/// Applies current sound policy and starts or coalesces one request.
///
/// ```zig
/// const outcome = playback.request(.needs_input);
/// ```
pub fn request(self: *SoundPlayback, kind: core.AgentSound) SoundRequestOutcome {
    if (!self.configuration.allows(kind)) {
        return .ignored;
    }

    if (self.active) {
        self.queued = playback_support.coalesce(self.queued, kind);
        return .queued;
    }

    std.debug.assert(self.queued == null);
    self.active = true;

    return .{ .start = kind };
}

/// Releases one completed worker and claims the coalesced successor.
///
/// ```zig
/// const next = playback.complete();
/// ```
pub fn complete(self: *SoundPlayback) ?core.AgentSound {
    std.debug.assert(self.active);
    self.active = false;
    const queued = self.queued;
    self.queued = null;

    const kind = queued orelse return null;
    if (!self.configuration.allows(kind)) {
        return null;
    }

    self.active = true;

    return kind;
}

/// Releases the token reserved before a worker failed to schedule.
///
/// ```zig
/// playback.schedulingFailed();
/// ```
pub fn schedulingFailed(self: *SoundPlayback) void {
    std.debug.assert(self.active);
    std.debug.assert(self.queued == null);
    self.active = false;
}

/// Replaces sound policy and removes queued work it no longer permits.
/// An already running host command remains active until completion.
///
/// ```zig
/// playback.configure(.{ .enabled = false });
/// ```
pub fn configure(self: *SoundPlayback, configuration: SoundPolicy) void {
    self.configuration = configuration;
    const queued = self.queued orelse return;
    if (!configuration.allows(queued)) {
        self.queued = null;
    }
}

/// Returns a value copy of the physical playback state.
///
/// ```zig
/// const state = playback.snapshot();
/// ```
pub fn snapshot(self: *const SoundPlayback) SoundSnapshot {
    return .{
        .configuration = self.configuration,
        .active = self.active,
        .queued = self.queued,
    };
}
