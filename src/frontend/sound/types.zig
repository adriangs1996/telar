//! Semantic host-sound values and local playback policy.

const std = @import("std");
const core = @import("telar-core");

pub const Kind = core.schema.AgentSound;

pub const Config = struct {
    enabled: bool = true,
    ready: bool = true,
    needs_input: bool = true,

    /// Reports whether local policy permits one semantic sound.
    ///
    /// ```zig
    /// if (configuration.allows(.ready)) {
    ///     _ = playback.request(.ready);
    /// }
    /// ```
    pub fn allows(configuration: Config, kind: Kind) bool {
        if (!configuration.enabled) {
            return false;
        }

        return switch (kind) {
            .ready => configuration.ready,
            .needs_input => configuration.needs_input,
        };
    }
};

test "sound configuration can disable each transition independently" {
    const configuration: Config = .{ .ready = false };

    try std.testing.expect(!configuration.allows(.ready));
    try std.testing.expect(configuration.allows(.needs_input));
    try std.testing.expect(!(Config{ .enabled = false }).allows(.needs_input));
}
