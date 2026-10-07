const core = @import("telar-core");
const SoundPolicy = @This();

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
pub fn allows(self: SoundPolicy, kind: core.AgentSound) bool {
    if (!self.enabled) {
        return false;
    }

    return switch (kind) {
        .ready => self.ready,
        .needs_input => self.needs_input,
    };
}
