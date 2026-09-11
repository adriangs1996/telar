//! Semantic host-sound values and local playback policy.

const std = @import("std");
const core = @import("telar-core");

pub const Kind = core.schema.AgentSound;

pub const Config = @import("Config.zig");

test "sound configuration can disable each transition independently" {
    const configuration: Config = .{ .ready = false };

    try std.testing.expect(!configuration.allows(.ready));
    try std.testing.expect(configuration.allows(.needs_input));
    try std.testing.expect(!(Config{ .enabled = false }).allows(.needs_input));
}
