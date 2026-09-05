//! Audible policy for committed agent status transitions.

const schema = @import("telar-core").schema;

/// Maps a committed transition to optional host sound.
/// Example: `const sound = soundForTransition(.working, .ready);`.
pub fn soundForTransition(previous: ?schema.AgentStatus, current: ?schema.AgentStatus) ?schema.AgentSound {
    if (previous != .working) {
        return null;
    }

    return switch (current orelse return null) {
        .ready, .done => .ready,
        .blocked => .needs_input,
        .unknown, .working, .failed => null,
    };
}
