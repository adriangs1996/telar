//! Audible policy for committed agent status transitions.

const core = @import("telar-core");

/// Maps a committed transition to optional host sound.
/// Example: `const sound = soundForTransition(.working, .ready);`.
pub fn soundForTransition(previous: ?core.AgentStatus, current: ?core.AgentStatus) ?core.AgentSound {
    if (previous != .working) {
        return null;
    }

    return switch (current orelse return null) {
        .ready, .done => .ready,
        .blocked => .needs_input,
        .unknown, .working, .failed => null,
    };
}
