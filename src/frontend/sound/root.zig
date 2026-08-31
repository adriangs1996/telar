//! Client-owned host audio policy, bounded playback and platform worker.

const types = @import("types.zig");
const playback = @import("playback.zig");
const worker = @import("worker.zig");

pub const Kind = types.Kind;
pub const Config = types.Config;
pub const Playback = playback.Playback;
pub const RequestOutcome = playback.RequestOutcome;
pub const Snapshot = playback.Snapshot;
pub const play = worker.play;

test {
    _ = types;
    _ = playback;
    _ = worker;
}
