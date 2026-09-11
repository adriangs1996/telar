const AgentSound = @import("telar-core").AgentSound;
const Config = @This();

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
pub fn allows(configuration: Config, kind: AgentSound) bool {
    if (!configuration.enabled) {
        return false;
    }

    return switch (kind) {
        .ready => configuration.ready,
        .needs_input => configuration.needs_input,
    };
}
